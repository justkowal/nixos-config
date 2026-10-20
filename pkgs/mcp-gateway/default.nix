{runCommand}:
runCommand "mcp-gateway-app" {} ''
  mkdir -p $out/app
  for f in gateway stdio_mcp fleet_mcp mail_mcp vault_mcp garmin_mcp garmin_login osm_mcp routing_mcp; do
    cp ${./.}/$f.py $out/app/$f.py
  done
  cp ${../agh-mcp/agh_mcp.py} $out/app/agh_mcp.py
''
