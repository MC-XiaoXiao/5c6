#!/usr/bin/env python3
"""Build a clean upstream restore host with explicit N49 iOS 6 custom restore fixes."""
import argparse
import hashlib
import difflib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile

REVISION = '45145e9fdc8458022c61a4b87bd029b866d5bcdc'


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Upstream source anchor missing or ambiguous')
    return text.replace(old, new)


def patch_sources(root):
    changes = []
    path = root / 'src/idevicerestore.c'
    original = source = path.read_text()
    source = replace_once(source,
        'if (!client->image4supported && (client->build_major > 8)) {',
        '/* An already running restored has no recovery endpoint for ApNonce. */\n'
        '\tif (!client->image4supported && (client->build_major > 8) && client->mode != MODE_RESTORE) {')
    source = replace_once(source,
        'if (client->ecid && event->device_info->ecid == client->ecid) {\n\t\t\tmutex_lock(&client->device_event_mutex);\n\t\t\tswitch (event->mode)',
        'if (client->ecid && event->device_info->ecid == client->ecid) {\n'
        '\t\t\t/* Normal USB descriptors are classified by usbmuxd, not recovery. */\n'
        '\t\t\tif ((int)event->mode == 0x12a8) return;\n\t\t\tmutex_lock(&client->device_event_mutex);\n\t\t\tswitch (event->mode)')
    source = replace_once(source, '\t\t\t// finally add manifest\n', '''			/* Preserve the custom iOS 6 AP identity; use Apple's latest BB identity. */
			plist_t native_bb = plist_dict_get_item(client->build_manifest, "Project5CBasebandIdentity");
			if (native_bb) {
				plist_t board = plist_access_path(native_bb, 2, "Info", "DeviceClass");
				const char* bbboard = board ? plist_get_string_ptr(board, NULL) : NULL;
				plist_t bb = plist_access_path(native_bb, 2, "Manifest", "BasebandFirmware");
				if (!bbboard || strcmp(bbboard, lcmodel) || !bb) {
					logger(LL_ERROR, "Native baseband manifest does not match this device\\n");
					return -1;
				}
				const char* fields[] = {"ApBoardID", "ApChipID", "ApSecurityDomain", "UniqueBuildID", "BbChipID",
					"BbProvisioningManifestKeyHash", "BbActivationManifestKeyHash", "BbCalibrationManifestKeyHash", "BbSkeyId", NULL};
				for (int i = 0; fields[i]; i++) {
					plist_t value = plist_dict_get_item(native_bb, fields[i]);
					if (value) plist_dict_set_item(build_identity, fields[i], plist_copy(value));
				}
				plist_dict_set_item(manifest, "BasebandFirmware", plist_copy(bb));
			}
			// finally add manifest
''')
    path.write_text(source)
    changes += difflib.unified_diff(original.splitlines(True), source.splitlines(True),
                                    fromfile='a/src/idevicerestore.c', tofile='b/src/idevicerestore.c')
    path = root / 'src/restore.c'
    original = source = path.read_text()
    source = replace_once(source, '\t// start the restore process\n', '''	/* Dedicated 5c iOS 6 path: preserve NOR and never transfer baseband. */
	if ((client->flags & FLAG_CUSTOM) && client->restore->protocol_version == 12 &&
	    client->device && (!strcmp(client->device->hardware_model, "n49ap") || !strcmp(client->device->hardware_model, "n48ap"))) {
		plist_dict_set_item(opts, "FlashNOR", plist_new_bool(0));
		plist_dict_set_item(opts, "UpdateBaseband", plist_new_bool(0));
		plist_dict_set_item(opts, "FormatForLwVM", plist_new_bool(1));
		plist_dict_remove_item(opts, "SystemImageFormat");
	}
	// start the restore process
''')
    source = replace_once(source,
        'static int restore_send_baseband_data(struct idevicerestore_client_t* client, plist_t message)\n{',
        '''static int restore_send_baseband_data(struct idevicerestore_client_t* client, plist_t message)
{
	/* Fail before any modem TSS request or payload transfer on this custom path. */
	if (client && client->restore && (client->flags & FLAG_CUSTOM) && client->restore->protocol_version == 12 &&
	    client->device && (!strcmp(client->device->hardware_model, "n49ap") || !strcmp(client->device->hardware_model, "n48ap"))) {
		logger(LL_ERROR, "Baseband transfer is disabled for the 5c iOS 6 restore path\\n");
		return -1;
	}''')
    source = replace_once(source, '\t// send file\n\tdict = plist_new_dict();\n\tplist_dict_set_item(dict, "BasebandData", plist_new_data(buffer, sz));', '''	/* Archive what the upstream BasebandData handler actually personalized. */
	const char* saved = getenv("PROJECT5C_BB_SAVE");
	if (saved && saved[0]) {
		if (write_file(saved, buffer, sz) < 0) {
			logger(LL_ERROR, "Could not save personalized baseband\\n");
			goto leave;
		}
		char* path = malloc(strlen(saved) + 16);
		if (!path) goto leave;
		char* xml = NULL;
		uint32_t length = 0;
		plist_t ticket = client->restore->bbtss ? client->restore->bbtss : response;
		plist_to_xml(ticket, &xml, &length);
		sprintf(path, "%s.tss.plist", saved);
		int written = xml ? write_file(path, xml, length) : -1;
		free(xml);
		xml = NULL;
		length = 0;
		plist_to_xml(arguments, &xml, &length);
		sprintf(path, "%s.query.plist", saved);
		if (!xml || write_file(path, xml, length) < 0) written = -1;
		free(xml); free(path);
		if (written < 0) goto leave;
	}
	// send file
	dict = plist_new_dict();
	plist_dict_set_item(dict, "BasebandData", plist_new_data(buffer, sz));''')
    path.write_text(source)
    changes += difflib.unified_diff(original.splitlines(True), source.splitlines(True),
                                    fromfile='a/src/restore.c', tofile='b/src/restore.c')
    return ''.join(changes)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sources = p.add_mutually_exclusive_group(required=True)
    sources.add_argument('--source', type=Path, help='Pinned upstream Git checkout')
    sources.add_argument('--source-archive', type=Path, help='Pinned source archive downloaded by tools.py')
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    if a.out.exists(): p.error('--out must be a new directory')
    if a.source_archive:
        lock = json.loads((Path(__file__).resolve().parents[2] / 'tools/locks/third-party-tools.json').read_text())['sources']['idevicerestore']
        archive = a.source_archive.read_bytes()
        if lock['commit'] != REVISION or hashlib.sha256(archive).hexdigest() != lock['sha256']:
            p.error('Source archive differs from the pinned snapshot')
    else:
        archive = subprocess.check_output(['git', '-C', str(a.source.resolve()), 'archive', REVISION])
    root = a.out.resolve()
    root.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if a.source_archive:
            for member in tar.getmembers():
                parts = Path(member.name).parts
                if len(parts) < 2: continue
                member.name = str(Path(*parts[1:]))
                tar.extract(member, root, filter='data')
        else:
            tar.extractall(root, filter='data')
    (root / '.tarball-version').write_text('1.0.0-native6-5c-no-baseband\n')
    diff = patch_sources(root)
    (root / 'native6-restore.patch').write_text(diff)
    env = dict(os.environ)
    # Build against system development libraries, with no bundled runtime override.
    env.pop('LD_LIBRARY_PATH', None)
    with (root / 'build.log').open('w') as log:
        for cmd in [['autoreconf', '-fi'], ['./configure', '--without-reverse-proxy'], ['make', '-j4']]:
            subprocess.run(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = root / 'src/idevicerestore'
    result = {'upstream_revision': REVISION, 'binary': str(binary),
              'source_export': 'tracked upstream commit only; no working tree modifications',
              'changes': ['Skip recovery nonce request in Restore mode', 'Classify normal USB through usbmuxd',
                          'Preserve NOR and request LwVM for custom iPhone 5c protocol 12',
                          'Disable baseband update and block BasebandData before signing or transfer on custom 5c restores',
                          'Save upstream-personalized BBFW and signing evidence']}
    (root / 'native6-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
