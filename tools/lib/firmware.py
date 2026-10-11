#!/usr/bin/env python3
"""Small, auditable helpers for legacy (IMG3-era) Apple firmware.

The tool deliberately does not patch signatures or modify source firmware.
Outputs are created separately and an existing, different file is never
overwritten unless --force is supplied.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import plistlib
import struct
import subprocess
import sys
import zlib
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from Crypto.Cipher import AES
except ImportError:  # pragma: no cover - small project-local fallback
    # The desktop image used for this project does not always ship
    # PyCryptodome.  Keep extraction reproducible with the system OpenSSL
    # command, without installing anything outside the workspace.  IMG3 DATA
    # is AES-CBC with no PKCS#7 padding, so the fallback has exactly the one
    # operation this tool needs.
    class _OpenSSLCipher:
        def __init__(self, key: bytes, iv: bytes):
            self._key = key
            self._iv = iv

        def decrypt(self, data: bytes) -> bytes:
            cipher = f"aes-{len(self._key) * 8}-cbc"
            result = subprocess.run(
                [
                    "openssl",
                    "enc",
                    f"-{cipher}",
                    "-d",
                    "-K",
                    self._key.hex(),
                    "-iv",
                    self._iv.hex(),
                    "-nopad",
                ],
                input=data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode:
                detail = result.stderr.decode("utf-8", errors="replace").strip()
                raise FirmwareFormatError(f"OpenSSL AES-CBC failed: {detail}")
            return result.stdout

    class AES:  # type: ignore[no-redef]
        block_size = 16
        MODE_CBC = 2

        @staticmethod
        def new(key: bytes, mode: int, iv: bytes) -> _OpenSSLCipher:
            if mode != AES.MODE_CBC:
                raise FirmwareFormatError("OpenSSL fallback only supports AES-CBC")
            return _OpenSSLCipher(key, iv)


IMG3_MAGIC = 0x496D6733
IMG3_HEADER_SIZE = 20
IMG3_TAG_HEADER_SIZE = 12
COMP_HEADER_SIZE = 0x180


class FirmwareFormatError(ValueError):
    """Raised when an input does not match the expected on-disk format."""


@dataclass(frozen=True)
class Img3Tag:
    name: str
    offset: int
    full_size: int
    data_size: int
    payload: bytes


@dataclass(frozen=True)
class Img3Image:
    total_size: int
    data_size: int
    shsh_offset: int
    image_type: str
    tags: tuple[Img3Tag, ...]


def _fourcc_from_le(value: int) -> str:
    return value.to_bytes(4, "little")[::-1].decode("ascii", errors="replace")


def parse_img3(blob: bytes) -> Img3Image:
    if len(blob) < IMG3_HEADER_SIZE:
        raise FirmwareFormatError("IMG3 is shorter than its 20-byte header")
    magic, total_size, data_size, shsh_offset, image_type = struct.unpack_from(
        "<5I", blob, 0
    )
    if magic != IMG3_MAGIC:
        raise FirmwareFormatError(f"not IMG3 (magic={magic:#010x})")
    if total_size != len(blob):
        raise FirmwareFormatError(
            f"IMG3 total size mismatch: header={total_size}, file={len(blob)}"
        )

    tags: list[Img3Tag] = []
    offset = IMG3_HEADER_SIZE
    while offset < len(blob):
        if offset + IMG3_TAG_HEADER_SIZE > len(blob):
            raise FirmwareFormatError(f"truncated IMG3 tag header at {offset:#x}")
        magic, full_size, used_size = struct.unpack_from("<3I", blob, offset)
        if full_size < IMG3_TAG_HEADER_SIZE:
            raise FirmwareFormatError(
                f"invalid IMG3 tag size {full_size} at {offset:#x}"
            )
        end = offset + full_size
        if end > len(blob):
            raise FirmwareFormatError(f"IMG3 tag at {offset:#x} exceeds file")
        padded_size = full_size - IMG3_TAG_HEADER_SIZE
        if used_size > padded_size:
            raise FirmwareFormatError(
                f"IMG3 tag at {offset:#x} has data_size > padded payload"
            )
        tags.append(
            Img3Tag(
                name=_fourcc_from_le(magic),
                offset=offset,
                full_size=full_size,
                data_size=used_size,
                payload=blob[offset + IMG3_TAG_HEADER_SIZE : end],
            )
        )
        offset = end

    if not any(tag.name == "DATA" for tag in tags):
        raise FirmwareFormatError("IMG3 has no DATA tag")
    return Img3Image(
        total_size=total_size,
        data_size=data_size,
        shsh_offset=shsh_offset,
        image_type=_fourcc_from_le(image_type),
        tags=tuple(tags),
    )


def extract_img3_data(blob: bytes, iv_hex: str | None, key_hex: str | None) -> bytes:
    image = parse_img3(blob)
    data_tag = next(tag for tag in image.tags if tag.name == "DATA")
    if (iv_hex is None) != (key_hex is None):
        raise FirmwareFormatError("both IV and key are required for IMG3 decryption")
    if iv_hex is None:
        return data_tag.payload[: data_tag.data_size]

    try:
        iv = bytes.fromhex(iv_hex)
        key = bytes.fromhex(key_hex or "")
    except ValueError as exc:
        raise FirmwareFormatError("IV/key must be hexadecimal") from exc
    if len(iv) != AES.block_size:
        raise FirmwareFormatError(f"AES-CBC IV must be 16 bytes, got {len(iv)}")
    if len(key) not in (16, 24, 32):
        raise FirmwareFormatError(f"AES key must be 16/24/32 bytes, got {len(key)}")
    if len(data_tag.payload) % AES.block_size:
        raise FirmwareFormatError("padded IMG3 DATA payload is not AES-block aligned")

    # IMG3 firmware newer than 3.1 encrypts the padded DATA allocation rather
    # than only data_size.  Truncate the decrypted padding afterwards.
    plain = AES.new(key, AES.MODE_CBC, iv).decrypt(data_tag.payload)
    return plain[: data_tag.data_size]


def decompress_complzss(blob: bytes) -> tuple[bytes, dict[str, Any]]:
    if len(blob) < COMP_HEADER_SIZE:
        raise FirmwareFormatError("complzss image is shorter than its 0x180-byte header")
    signature, compression, checksum, unpacked_size, packed_size = struct.unpack_from(
        ">4s4sIII", blob, 0
    )
    if signature != b"comp" or compression != b"lzss":
        raise FirmwareFormatError(
            f"not complzss (signature={signature!r}, compression={compression!r})"
        )
    packed = blob[COMP_HEADER_SIZE : COMP_HEADER_SIZE + packed_size]
    if len(packed) != packed_size:
        raise FirmwareFormatError(
            f"truncated LZSS stream: expected {packed_size}, got {len(packed)}"
        )

    ring_size = 4096
    max_match = 18
    threshold = 2
    ring = bytearray(ring_size + max_match - 1)
    ring[: ring_size - max_match] = b" " * (ring_size - max_match)
    ring_pos = ring_size - max_match
    src_pos = 0
    flags = 0
    output = bytearray()

    while src_pos < len(packed) and len(output) < unpacked_size:
        flags >>= 1
        if (flags & 0x100) == 0:
            flags = packed[src_pos] | 0xFF00
            src_pos += 1
        if flags & 1:
            if src_pos >= len(packed):
                break
            value = packed[src_pos]
            src_pos += 1
            output.append(value)
            ring[ring_pos] = value
            ring_pos = (ring_pos + 1) & (ring_size - 1)
        else:
            if src_pos + 1 >= len(packed):
                break
            match_pos = packed[src_pos]
            length_byte = packed[src_pos + 1]
            src_pos += 2
            match_pos |= (length_byte & 0xF0) << 4
            match_length = (length_byte & 0x0F) + threshold + 1
            for index in range(match_length):
                value = ring[(match_pos + index) & (ring_size - 1)]
                output.append(value)
                ring[ring_pos] = value
                ring_pos = (ring_pos + 1) & (ring_size - 1)
                if len(output) > unpacked_size:
                    raise FirmwareFormatError("LZSS output exceeded declared size")

    if len(output) != unpacked_size:
        raise FirmwareFormatError(
            f"LZSS size mismatch: expected {unpacked_size}, got {len(output)}"
        )
    actual_checksum = zlib.adler32(output) & 0xFFFFFFFF
    if actual_checksum != checksum:
        raise FirmwareFormatError(
            f"Adler-32 mismatch: expected {checksum:#010x}, got {actual_checksum:#010x}"
        )
    metadata = {
        "format": "complzss",
        "compressed_size": packed_size,
        "uncompressed_size": unpacked_size,
        "adler32": f"{actual_checksum:08x}",
        "compressed_bytes_consumed": src_pos,
    }
    return bytes(output), metadata


def _decode_dt_value(raw: bytes) -> dict[str, Any]:
    result: dict[str, Any] = {
        "length": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    if len(raw) <= 128:
        result["hex"] = raw.hex()
    else:
        result["head_hex"] = raw[:64].hex()
    parts = raw.rstrip(b"\0").split(b"\0")
    if parts and all(part and all(0x20 <= byte < 0x7F for byte in part) for part in parts):
        result["strings"] = [part.decode("ascii") for part in parts]
    if len(raw) == 4:
        result["u32_le"] = struct.unpack("<I", raw)[0]
    return result


def parse_device_tree(blob: bytes) -> dict[str, Any]:
    def parse_node(offset: int, depth: int) -> tuple[dict[str, Any], int]:
        if depth > 256:
            raise FirmwareFormatError("device-tree recursion limit exceeded")
        if offset + 8 > len(blob):
            raise FirmwareFormatError(f"truncated device-tree node at {offset:#x}")
        property_count, child_count = struct.unpack_from("<II", blob, offset)
        offset += 8
        properties: list[dict[str, Any]] = []
        for _ in range(property_count):
            if offset + 36 > len(blob):
                raise FirmwareFormatError(f"truncated device-tree property at {offset:#x}")
            raw_name = blob[offset : offset + 32]
            encoded_length = struct.unpack_from("<I", blob, offset + 32)[0]
            offset += 36
            length = encoded_length & 0x00FFFFFF
            flags = encoded_length >> 24
            end = offset + length
            if end > len(blob):
                raise FirmwareFormatError(f"device-tree property at {offset:#x} exceeds file")
            value = blob[offset:end]
            offset = (end + 3) & ~3
            properties.append(
                {
                    "name": raw_name.split(b"\0", 1)[0].decode("ascii", errors="replace"),
                    "flags": flags,
                    "value": _decode_dt_value(value),
                }
            )
        children: list[dict[str, Any]] = []
        for _ in range(child_count):
            child, offset = parse_node(offset, depth + 1)
            children.append(child)
        return {
            "property_count": property_count,
            "child_count": child_count,
            "properties": properties,
            "children": children,
        }, offset

    root, end = parse_node(0, 0)
    trailing = blob[end:]
    if trailing.strip(b"\0"):
        raise FirmwareFormatError(f"non-zero trailing device-tree data at {end:#x}")
    root["parsed_size"] = end
    root["file_size"] = len(blob)
    return root


def extract_macho32_section(blob: bytes, segment_name: str, section_name: str) -> bytes:
    """Extract one section from a little-endian 32-bit Mach-O image."""
    if len(blob) < 28:
        raise FirmwareFormatError("Mach-O image is shorter than its header")
    magic, _cpu, _subcpu, _type, command_count, command_size, _flags = struct.unpack_from(
        "<IiiIIII", blob, 0
    )
    if magic != 0xFEEDFACE:
        raise FirmwareFormatError(f"not little-endian Mach-O 32 (magic={magic:#010x})")
    command_offset = 28
    command_end = command_offset + command_size
    if command_end > len(blob):
        raise FirmwareFormatError("Mach-O load commands exceed file")
    for _ in range(command_count):
        if command_offset + 8 > command_end:
            raise FirmwareFormatError("truncated Mach-O load command")
        command, size = struct.unpack_from("<II", blob, command_offset)
        if size < 8 or command_offset + size > command_end:
            raise FirmwareFormatError("invalid Mach-O load command size")
        if command == 1:  # LC_SEGMENT
            if size < 56:
                raise FirmwareFormatError("truncated LC_SEGMENT")
            segment = blob[command_offset + 8 : command_offset + 24].split(b"\0", 1)[0]
            section_count = struct.unpack_from("<I", blob, command_offset + 48)[0]
            section_offset = command_offset + 56
            if section_offset + section_count * 68 > command_offset + size:
                raise FirmwareFormatError("Mach-O sections exceed LC_SEGMENT")
            for _section_index in range(section_count):
                section = blob[section_offset : section_offset + 16].split(b"\0", 1)[0]
                section_segment = blob[section_offset + 16 : section_offset + 32].split(
                    b"\0", 1
                )[0]
                _address, section_size, file_offset = struct.unpack_from(
                    "<III", blob, section_offset + 32
                )
                if (
                    segment.decode("ascii", errors="replace") == segment_name
                    and section_segment.decode("ascii", errors="replace") == segment_name
                    and section.decode("ascii", errors="replace") == section_name
                ):
                    end = file_offset + section_size
                    if end > len(blob):
                        raise FirmwareFormatError("Mach-O section exceeds file")
                    return blob[file_offset:end]
                section_offset += 68
        command_offset += size
    raise FirmwareFormatError(f"Mach-O section {segment_name},{section_name} not found")


def parse_prelink_xml(fragment: bytes) -> dict[str, Any]:
    """Parse Apple's prelink XML fragment, including ID/IDREF objects.

    Kernelcache prelink data is not a normal plist: it omits the plist wrapper,
    represents integers as hexadecimal, and deduplicates values with ID/IDREF.
    """
    fragment = fragment.rstrip(b"\0")
    try:
        root = ET.fromstring(b"<plist>" + fragment + b"</plist>")
    except ET.ParseError as exc:
        raise FirmwareFormatError(f"invalid prelink XML: {exc}") from exc
    references: dict[str, Any] = {}

    def decode(element: ET.Element) -> Any:
        reference = element.attrib.get("IDREF")
        if reference is not None:
            if reference not in references:
                raise FirmwareFormatError(f"prelink XML has forward/missing IDREF={reference}")
            return references[reference]

        tag = element.tag
        if tag == "dict":
            children = list(element)
            if len(children) % 2:
                raise FirmwareFormatError("prelink XML dict has an odd child count")
            value: Any = {}
            for index in range(0, len(children), 2):
                key = decode(children[index])
                if not isinstance(key, str):
                    raise FirmwareFormatError("prelink XML dict key is not a string")
                value[key] = decode(children[index + 1])
        elif tag == "array":
            value = [decode(child) for child in element]
        elif tag in ("key", "string"):
            value = element.text or ""
        elif tag == "integer":
            text = (element.text or "0").strip()
            value = int(text, 0)
        elif tag == "real":
            text = (element.text or "0").strip()
            value = float(text)
        elif tag == "data":
            value = base64.b64decode("".join((element.text or "").split()))
        elif tag == "true":
            value = True
        elif tag == "false":
            value = False
        elif tag == "date":
            value = element.text or ""
        else:
            raise FirmwareFormatError(f"unsupported prelink XML element <{tag}>")

        object_id = element.attrib.get("ID")
        if object_id is not None:
            references[object_id] = value
        return value

    if len(root) != 1:
        raise FirmwareFormatError("prelink XML must contain exactly one root value")
    value = decode(root[0])
    if not isinstance(value, dict):
        raise FirmwareFormatError("prelink XML root is not a dictionary")
    return value


def summarize_prelink(prelink: dict[str, Any]) -> dict[str, Any]:
    entries = prelink.get("_PrelinkInfoDictionary")
    if not isinstance(entries, list):
        raise FirmwareFormatError("prelink dictionary has no _PrelinkInfoDictionary array")
    summaries: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        personalities: list[dict[str, Any]] = []
        raw_personalities = entry.get("IOKitPersonalities", {})
        if isinstance(raw_personalities, dict):
            for personality_name, personality in raw_personalities.items():
                if not isinstance(personality, dict):
                    continue
                summary = {"name": personality_name}
                for key in (
                    "IOClass",
                    "IOProviderClass",
                    "IONameMatch",
                    "IOResourceMatch",
                    "IOMatchCategory",
                ):
                    if key in personality:
                        summary[key] = personality[key]
                implementation_classes = sorted(
                    {
                        value
                        for key, value in personality.items()
                        if isinstance(value, str)
                        and (
                            key == "IOClass"
                            or (key.endswith("Class") and key != "IOProviderClass")
                        )
                    }
                )
                if implementation_classes:
                    summary["implementation_classes"] = implementation_classes
                personalities.append(summary)
        summary = {
            "bundle_id": entry.get("CFBundleIdentifier"),
            "bundle_name": entry.get("CFBundleName"),
            "bundle_version": entry.get("CFBundleVersion"),
            "compatible_version": entry.get("OSBundleCompatibleVersion"),
            "libraries": entry.get("OSBundleLibraries", {}),
            "executable": entry.get("CFBundleExecutable"),
            "path": entry.get("_PrelinkBundlePath"),
            "load_address": entry.get("_PrelinkExecutableLoadAddr"),
            "source_address": entry.get("_PrelinkExecutableSourceAddr"),
            "size": entry.get("_PrelinkExecutableSize"),
            "kmod_info": entry.get("_PrelinkKmodInfo"),
            "personalities": sorted(personalities, key=lambda item: str(item.get("name"))),
        }
        summaries.append(summary)
    summaries.sort(key=lambda item: str(item.get("bundle_id")))
    return {"kext_count": len(summaries), "kexts": summaries}


def _write_verified(path: Path, data: bytes, force: bool) -> str:
    if path.exists():
        old = path.read_bytes()
        if old == data:
            return "unchanged"
        if not force:
            raise FileExistsError(f"refusing to overwrite different file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return "written"


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ensure_external_output(
    path: Path, expected_sha256: str, command: list[str]
) -> tuple[str, str]:
    if path.exists():
        actual = _sha256_file(path)
        if actual != expected_sha256:
            raise FirmwareFormatError(
                f"existing output hash mismatch for {path}: expected {expected_sha256}, got {actual}"
            )
        return "unchanged", actual
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(command, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise FirmwareFormatError(f"external unpack command failed: {command[0]}") from exc
    actual = _sha256_file(path)
    if actual != expected_sha256:
        raise FirmwareFormatError(
            f"new output hash mismatch for {path}: expected {expected_sha256}, got {actual}"
        )
    return "written", actual


def cmd_img3_info(args: argparse.Namespace) -> None:
    image = parse_img3(args.input.read_bytes())
    print(
        json.dumps(
            {
                "path": str(args.input),
                "total_size": image.total_size,
                "data_size": image.data_size,
                "shsh_offset": image.shsh_offset,
                "image_type": image.image_type,
                "tags": [
                    {
                        "name": tag.name,
                        "offset": tag.offset,
                        "full_size": tag.full_size,
                        "data_size": tag.data_size,
                    }
                    for tag in image.tags
                ],
            },
            indent=2,
        )
    )


def cmd_img3_decrypt(args: argparse.Namespace) -> None:
    plain = extract_img3_data(args.input.read_bytes(), args.iv, args.key)
    state = _write_verified(args.output, plain, args.force)
    print(json.dumps({"output": str(args.output), "state": state, "sha256": _sha256(plain)}))


def cmd_lzss(args: argparse.Namespace) -> None:
    plain, metadata = decompress_complzss(args.input.read_bytes())
    state = _write_verified(args.output, plain, args.force)
    metadata.update({"output": str(args.output), "state": state, "sha256": _sha256(plain)})
    print(json.dumps(metadata))


def cmd_kernelcache(args: argparse.Namespace) -> None:
    decrypted = extract_img3_data(args.input.read_bytes(), args.iv, args.key)
    kernel, metadata = decompress_complzss(decrypted)
    decrypted_path = args.output.with_suffix(args.output.suffix + ".complzss")
    dec_state = _write_verified(decrypted_path, decrypted, args.force)
    kernel_state = _write_verified(args.output, kernel, args.force)
    result = {
        **metadata,
        "input": str(args.input),
        "decrypted_output": str(decrypted_path),
        "decrypted_state": dec_state,
        "decrypted_sha256": _sha256(decrypted),
        "kernel_output": str(args.output),
        "kernel_state": kernel_state,
        "kernel_sha256": _sha256(kernel),
        "kernel_magic": kernel[:4].hex(),
    }
    print(json.dumps(result, indent=2))


def cmd_devicetree(args: argparse.Namespace) -> None:
    tree = parse_device_tree(args.input.read_bytes())
    data = _json_bytes(tree)
    state = _write_verified(args.output, data, args.force)
    print(json.dumps({"output": str(args.output), "state": state, "sha256": _sha256(data)}))


def cmd_batch(args: argparse.Namespace) -> None:
    config = json.loads(args.config.read_text(encoding="utf-8"))
    selected = args.build or list(config["builds"])
    results: list[dict[str, Any]] = []
    for build_name in selected:
        build = config["builds"][build_name]
        source_dir = args.firmware_root / build["source_directory"]
        output_dir = args.output_root / build_name
        for item in build["components"]:
            source = source_dir / item["path"]
            output = output_dir / item["output"]
            kind = item["kind"]
            if kind == "filevault-dmg":
                if not source.is_file():
                    raise FileNotFoundError(source)
                if not args.vfdecrypt.is_file():
                    raise FileNotFoundError(args.vfdecrypt)
                if not args.dmg2img.is_file():
                    raise FileNotFoundError(args.dmg2img)
                udif_state, udif_hash = _ensure_external_output(
                    output,
                    item["output_sha256"],
                    [
                        str(args.vfdecrypt),
                        "-i",
                        str(source),
                        "-k",
                        item["key"],
                        "-o",
                        str(output),
                    ],
                )
                hfs_output = output_dir / item["hfs_output"]
                hfs_state, hfs_hash = _ensure_external_output(
                    hfs_output,
                    item["hfs_sha256"],
                    [
                        str(args.dmg2img),
                        "-s",
                        "-p",
                        str(item["partition"]),
                        str(output),
                        str(hfs_output),
                    ],
                )
                results.append(
                    {
                        "build": build_name,
                        "component": item["name"],
                        "kind": kind,
                        "source": str(source),
                        "output": str(output),
                        "state": udif_state,
                        "sha256": udif_hash,
                        "hfs_output": str(hfs_output),
                        "hfs_state": hfs_state,
                        "hfs_sha256": hfs_hash,
                        "partition": item["partition"],
                    }
                )
                continue
            if not source.is_file():
                raise FileNotFoundError(source)
            decrypted = extract_img3_data(source.read_bytes(), item.get("iv"), item.get("key"))
            state = _write_verified(output, decrypted, args.force)
            result: dict[str, Any] = {
                "build": build_name,
                "component": item["name"],
                "kind": kind,
                "source": str(source),
                "output": str(output),
                "state": state,
                "sha256": _sha256(decrypted),
                "size": len(decrypted),
            }
            if kind == "kernelcache":
                kernel, lzss_metadata = decompress_complzss(decrypted)
                kernel_path = output.with_suffix(".macho")
                result["kernel_state"] = _write_verified(kernel_path, kernel, args.force)
                result["kernel_output"] = str(kernel_path)
                result["kernel_sha256"] = _sha256(kernel)
                result["kernel_size"] = len(kernel)
                result["kernel_magic"] = kernel[:4].hex()
                result["lzss"] = lzss_metadata
                prelink_fragment = extract_macho32_section(
                    kernel, "__PRELINK_INFO", "__info"
                ).rstrip(b"\0")
                prelink_path = output_dir / "prelink-info.fragment.xml"
                result["prelink_state"] = _write_verified(
                    prelink_path, prelink_fragment + b"\n", args.force
                )
                result["prelink_output"] = str(prelink_path)
                prelink_summary = summarize_prelink(parse_prelink_xml(prelink_fragment))
                prelink_summary_path = output_dir / "prelink-kexts.json"
                prelink_summary_data = _json_bytes(prelink_summary)
                result["prelink_summary_state"] = _write_verified(
                    prelink_summary_path, prelink_summary_data, args.force
                )
                result["prelink_summary_output"] = str(prelink_summary_path)
                result["kext_count"] = prelink_summary["kext_count"]
            elif kind == "devicetree":
                tree_path = output.with_suffix(".json")
                tree_data = _json_bytes(parse_device_tree(decrypted))
                result["tree_state"] = _write_verified(tree_path, tree_data, args.force)
                result["tree_output"] = str(tree_path)
                result["tree_sha256"] = _sha256(tree_data)
            results.append(result)

    report = {"config": str(args.config), "results": results}
    report_path = args.output_root / "unpack-report.json"
    # Keep the persisted report deterministic across idempotent reruns.  State
    # fields (written/unchanged) remain useful in stdout but are transient.
    disk_results = [
        {key: value for key, value in result.items() if not key.endswith("state")}
        for result in results
    ]
    disk_report = {"config": str(args.config), "results": disk_results}
    _write_verified(report_path, _json_bytes(disk_report), True)
    print(json.dumps(report, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    info = subparsers.add_parser("img3-info", help="inspect an IMG3 container")
    info.add_argument("input", type=Path)
    info.set_defaults(func=cmd_img3_info)

    decrypt = subparsers.add_parser("img3-decrypt", help="extract/decrypt IMG3 DATA")
    decrypt.add_argument("input", type=Path)
    decrypt.add_argument("output", type=Path)
    decrypt.add_argument("--iv", required=True)
    decrypt.add_argument("--key", required=True)
    decrypt.add_argument("--force", action="store_true")
    decrypt.set_defaults(func=cmd_img3_decrypt)

    lzss = subparsers.add_parser("lzss-decompress", help="decompress a complzss image")
    lzss.add_argument("input", type=Path)
    lzss.add_argument("output", type=Path)
    lzss.add_argument("--force", action="store_true")
    lzss.set_defaults(func=cmd_lzss)

    kernel = subparsers.add_parser("kernelcache", help="decrypt and decompress an IMG3 kernelcache")
    kernel.add_argument("input", type=Path)
    kernel.add_argument("output", type=Path)
    kernel.add_argument("--iv", required=True)
    kernel.add_argument("--key", required=True)
    kernel.add_argument("--force", action="store_true")
    kernel.set_defaults(func=cmd_kernelcache)

    tree = subparsers.add_parser("devicetree-json", help="convert a decrypted Apple device tree to JSON")
    tree.add_argument("input", type=Path)
    tree.add_argument("output", type=Path)
    tree.add_argument("--force", action="store_true")
    tree.set_defaults(func=cmd_devicetree)

    batch = subparsers.add_parser("batch", help="unpack configured firmware components")
    batch.add_argument("--config", type=Path, default=Path("config/firmware_keys.json"))
    batch.add_argument("--firmware-root", type=Path, default=Path("firmware"))
    batch.add_argument("--output-root", type=Path, default=Path("work/unpacked"))
    batch.add_argument(
        "--vfdecrypt", type=Path, default=Path("third_party/dmg2img/vfdecrypt")
    )
    batch.add_argument(
        "--dmg2img", type=Path, default=Path("third_party/dmg2img/dmg2img")
    )
    batch.add_argument("--build", action="append", choices=[
        "iPhone5,2_6.1.3_10B329",
        "iPhone5,4_7.0.1_11A470a",
        "iPhone5,4_10.3.3_14G60",
    ])
    batch.add_argument("--force", action="store_true")
    batch.set_defaults(func=cmd_batch)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except (FirmwareFormatError, FileExistsError, FileNotFoundError, KeyError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
