def asnum:
  if type=="number" then .
  elif type=="string" and test("^0[xX][0-9a-fA-F]+$") then
    ascii_downcase|.[2:]|explode|reduce .[] as $c (0; . * 16 + (if $c<=57 then $c-48 else $c-87 end))
  else tonumber end;
