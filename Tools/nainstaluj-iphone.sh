#!/bin/zsh
# Sestaví Vlnku pro iPhone, podepíše ji bezplatným Apple ID a nahraje do telefonu
# (kabelem nebo přes Wi‑Fi). Bezplatný podpis platí 7 dní – proto tenhle skript
# pouští launchd automaticky každé 3 dny (viz Tools/zapni-automatiku.sh).
set -e
cd "$(dirname "$0")/.."
LOG=build/ios-instalace.log
mkdir -p build
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M') ==="

# ID týmu: z Tools/.team (uloží se při prvním běhu), jinak z nastavení Xcode
TEAM_FILE=Tools/.team
if [ -f $TEAM_FILE ]; then TEAM=$(cat $TEAM_FILE)
else
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
         | grep -E 'teamID = ' | head -1 | sed -E 's/.*teamID = "?([A-Z0-9]+)"?;.*/\1/')
  [ -z "$TEAM" ] && { echo "Chybí Apple ID v Xcode (Xcode → Settings → Accounts)."; exit 1; }
  echo $TEAM > $TEAM_FILE
fi

# iPhone: první spárovaný, který je teď dostupný
JSON=$(mktemp)
xcrun devicectl list devices --json-output $JSON >/dev/null 2>&1 || true
DEVICE=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))["result"]["devices"]
ok=[x for x in d if x.get("hardwareProperties",{}).get("platform")=="iOS"
    and x.get("connectionProperties",{}).get("tunnelState")!="unavailable"]
print(ok[0]["identifier"]+" "+ok[0]["hardwareProperties"]["udid"] if ok else "")' $JSON)
rm -f $JSON
UDID=${DEVICE#* }; DEVICE=${DEVICE%% *}
[ -z "$DEVICE" ] && { echo "iPhone není na dosah (stejná Wi‑Fi, odemčený nebo nabíjí). Zkusím to příště."; exit 2; }

xcodebuild -project Vlnka.xcodeproj -scheme Vlnka -configuration Release \
  -destination "platform=iOS,id=$UDID" -derivedDataPath build/ios \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM build -quiet

xcrun devicectl device install app --device $DEVICE build/ios/Build/Products/Release-iphoneos/Vlnka.app
echo "Hotovo: Vlnka nahraná do iPhonu, podpis platí dalších 7 dní."
