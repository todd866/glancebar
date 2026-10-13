#!/bin/zsh
# Starlink router probe: run once on the trip Wi-Fi, before Glancebar's Starlink row is built.
# Answers docs/superpowers/specs/2026-10-13-starlink-cap-design.md "Open" questions:
#   1. what the per-client counters count from   2. whether LAN config writes work
#   3. whether anything local reports cycle usage
# Read-only unless --test-block <MAC> is given; that blocks one device for ~20 s, then restores
# the router's original client configs exactly.
# Usage: tools/starlink-probe.sh [--minutes 10] [--test-block aa:bb:cc:dd:ee:ff]
set -euo pipefail

ROUTER=192.168.1.1:9000
DISH=192.168.100.1:9200
MINUTES=10
BLOCK_MAC=""
while (( $# )); do
    case $1 in
        --minutes) MINUTES=$2; shift 2 ;;
        --test-block) BLOCK_MAC=${2:l}; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

command -v grpcurl >/dev/null || { echo "needs grpcurl: brew install grpcurl" >&2; exit 1; }
command -v jq >/dev/null || { echo "needs jq" >&2; exit 1; }

OUT=~/.local/state/starlink-cap/probe-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
echo "output: $OUT"

# Reflection first; fall back to the community protos if the device does not offer it.
PROTO_ARGS=()
if ! grpcurl -plaintext -max-time 5 "$ROUTER" list >"$OUT/router-services.txt" 2>"$OUT/reflection.err"; then
    echo "no reflection on router; using community protos"
    P=~/.local/state/starlink-cap/protos
    if [[ ! -d $P/spacex ]]; then
        T=$(mktemp -d)
        git clone -q --depth 1 https://github.com/Eitol/starlink-client "$T/sc"
        mkdir -p "$P" && cp -R "$T/sc/proto/spacex" "$P/"
    fi
    PROTO_ARGS=(-import-path "$P" -proto spacex/api/device/device.proto)
fi

call() {   # call <host:port> <json request> -> stdout JSON
    grpcurl -plaintext -max-time 10 "${PROTO_ARGS[@]}" -d "$2" "$1" SpaceX.API.Device.Device/Handle
}

echo "== reflection / services"
cat "$OUT/router-services.txt" 2>/dev/null || true
grpcurl -plaintext -max-time 5 "$ROUTER" describe SpaceX.API.Device.Request >"$OUT/router-request.txt" 2>&1 || true
grpcurl -plaintext -max-time 5 "$ROUTER" describe SpaceX.API.Device.WifiClient >"$OUT/router-wificlient.txt" 2>&1 || true

echo "== one-shot reads"
for req in get_device_info wifi_get_config wifi_get_clients get_status; do
    call "$ROUTER" "{\"$req\":{}}" >"$OUT/router-$req.json" 2>&1 && echo "router $req ok" || echo "router $req: $(head -1 "$OUT/router-$req.json")"
done
for req in get_device_info get_status get_history; do
    call "$DISH" "{\"$req\":{}}" >"$OUT/dish-$req.json" 2>&1 && echo "dish $req ok" || echo "dish $req: $(head -1 "$OUT/dish-$req.json")"
done

echo "== anything that looks like cycle usage"
grep -il -E 'usage|quota|data_?limit|billing|cycle|gb' "$OUT"/*.json "$OUT"/*.txt 2>/dev/null | sed 's/^/  /' || true
grep -ho -iE '"[a-zA-Z_]*(usage|quota|billing|cycle|limit)[a-zA-Z_]*"' "$OUT"/*.json 2>/dev/null | sort -u | sed 's/^/  field /' || true

echo "== sampling client counters every 30 s for $MINUTES min (use the network meanwhile)"
SAMPLES="$OUT/samples.tsv"
print -r -- "time\tmac\tname\tdownload_mb\tupload_mb\trx_bytes\ttx_bytes\tassociated_s\tblocked" >"$SAMPLES"
end=$(( $(date +%s) + MINUTES * 60 ))
while (( $(date +%s) < end )); do
    call "$ROUTER" '{"wifi_get_clients":{}}' 2>/dev/null | jq -r --arg t "$(date +%s)" '
        (.wifiGetClients.clients // [])[] |
        [$t, .macAddress, (.givenName // .name // ""), (.downloadMb // 0), (.uploadMb // 0),
         (.rxStats.bytes // 0), (.txStats.bytes // 0), (.associatedTimeS // 0), (.blocked // false)] | @tsv' >>"$SAMPLES" || true
    sleep 30
done
echo "samples: $(($(wc -l <"$SAMPLES") - 1)) rows"

if [[ -n $BLOCK_MAC ]]; then
    echo "== LAN write test: blocking $BLOCK_MAC for ~20 s"
    call "$ROUTER" '{"wifi_get_config":{}}' >"$OUT/config-before.json"
    jq -c '.wifiGetConfig.wifiConfig.clientConfigs // []' "$OUT/config-before.json" >"$OUT/client-configs-original.json"
    jq -c --arg mac "$BLOCK_MAC" '
        [.[] | select((.macAddress // "" | ascii_downcase) != $mac)] +
        [{macAddress: $mac, weeklyBlockSchedules: [{blockRanges: [{startMinutes: 0, endMinutes: 10080}]}]}]' \
        "$OUT/client-configs-original.json" >"$OUT/client-configs-blocked.json"
    restore() {
        call "$ROUTER" "{\"wifi_set_config\":{\"wifi_config\":{\"client_configs\":$(cat "$OUT/client-configs-original.json"),\"apply_client_configs\":true}}}" \
            >"$OUT/restore.json" 2>&1 && echo "restored original client configs" || echo "RESTORE FAILED: see $OUT/restore.json and fix in the Starlink app"
    }
    trap restore EXIT
    if call "$ROUTER" "{\"wifi_set_config\":{\"wifi_config\":{\"client_configs\":$(cat "$OUT/client-configs-blocked.json"),\"apply_client_configs\":true}}}" >"$OUT/set.json" 2>&1; then
        echo "write accepted"
        sleep 20
        call "$ROUTER" '{"wifi_get_clients":{}}' | jq -r --arg mac "$BLOCK_MAC" \
            '(.wifiGetClients.clients // [])[] | select((.macAddress|ascii_downcase) == $mac) | "blocked=\(.blocked // false)"' | tee "$OUT/block-result.txt"
    else
        echo "write REFUSED: $(head -3 "$OUT/set.json")"
    fi
fi

echo "== done. Send Claude this folder: $OUT"
