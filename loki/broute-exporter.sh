#!/bin/bash
set -u

DEVICE="/dev/ttyUSB0"
PAWD="0123456789AB"
RBID="00112233445566778899AABBCCDDEEFF"
CHANNEL="21" # SKSCAN Channel:
PANID="8888" # SKSCAN Pan ID:
IPADDR="FE80:0000:0000:0000:1034:5678:ABCD:EF02" # SKLL64 <Addr>
SIDE="0"
loki_url="http://loki.home.arpa:3100/loki/api/v1/push"
SEND_COOLDOWN=120
REJOIN_INTERVAL=3600

stty -F "$DEVICE" 115200 raw -echo -icrnl -onlcr

send_cmd() {
  #echo "==> $1" # display and timeout for do_init()
  sleep 1
  echo -e "$1\r\n" > "$DEVICE"
}

do_init() {
  AUTHED=0
  WAITING_REPLY=0
  echo "Initializing..."
  send_cmd "SKTERM"k
  send_cmd "SKRESET"
  send_cmd "SKSETPWD C $PAWD"
  send_cmd "SKSETRBID $RBID"
  send_cmd "SKSCAN 2 FFFFFFFF 8 0"
}

send_req_e7e8() {
  # 送信抑制
  [[ "$WAITING_REPLY" -eq 1 ]] && return # send_req_e7e8()の応答待ち
  [[ "$AUTHED" -ne 1 ]] && return # EVENT 25が見えてない
  echo "Waiting $SEND_COOLDOWN seconds..."
  sleep $SEND_COOLDOWN

  echo "==> SEND 0xE7/0xE8"
  {
    printf "SKSENDTO 1 $IPADDR 0E1A 1 ${SIDE} 0012 "
    printf '\x10\x81\x00\x01\x05\xff\x01\x02\x88\x01\x62\x02\xe7\x00\xe8\x00'
    printf '\r\n'
  } > "$DEVICE"

  WAITING_REPLY=1
}

cleanup() {
  send_cmd "SKTERM"
  exit 0
}
trap cleanup EXIT INT TERM

# 初期設定
do_init

LAST_RX_TIME=$(date +%s)
cat "$DEVICE" | while read -r line; do
  echo "$line"
  now=$(date +%s)

  # ---- 長時間無通信ならREJOIN ----
  if (( now - LAST_RX_TIME > REJOIN_INTERVAL )); then
    echo "NO RX for $REJOIN_INTERVAL seconds."
    do_init
  fi

  case "$line" in
      
    *"EVENT 22"*)
      echo "<== SCAN FINISHED"
      
      # PANA接続開始
      echo "==> JOIN"
      send_cmd "SKSREG S2 $CHANNEL"
      send_cmd "SKSREG S3 $PANID"
      send_cmd "SKJOIN $IPADDR"
      ;;

    *"EVENT 2"[46789]*)
      echo "<== PANA AUTH FAILED"
      echo "Restarting to work around the stacking bug in Event 25..." # EVENT 29
      AUTHED=0
      cleanup
      ;;

    *"EVENT 25"*)
      echo "<== PANA AUTH SUCCEED"
      AUTHED=1

      # JOIN直後にまず1回要求
      send_req_e7e8
      ;;

    *"ERXUDP"*)
      [ "$AUTHED" -eq 0 ] && continue

      data=$(echo "$line" | awk '{print $NF}')

      # 随時動作を取得 瞬時電力計測値0xE7, 瞬時電流計測値0xE8
      if [[ "$data" =~ ^1081000102880105FF0172 ]]; then
        WAITING_REPLY=0
        LAST_RX_TIME=$now

        inst_power=$((16#${data:28:8}))

        raw_r=$((16#${data:40:4}))
        inst_current_phase_r="$(printf "%d.%d" $((raw_r/10)) $((raw_r%10)))"
        raw_t=$((16#${data:44:4}))
        inst_current_phase_t="$(printf "%d.%d" $((raw_t/10)) $((raw_t%10)))"

        epoch_time=$(date +%s%N)

        echo "<== Power=$inst_power W  R=$inst_current_phase_r A  T=$inst_current_phase_t A"

        json_payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": { "job": "echonet-lite", "epc": "e7" },
      "values": [ [ "$epoch_time", "{\"value\": $inst_power}" ] ]
    },
    {
      "stream": { "job": "echonet-lite", "epc": "e8", "phase": "r" },
      "values": [ [ "$epoch_time", "{\"value\": $inst_current_phase_r}" ] ]
    },
    {
      "stream": { "job": "echonet-lite", "epc": "e8", "phase": "t" },
      "values": [ [ "$epoch_time", "{\"value\": $inst_current_phase_t}" ] ]
    }
  ]
}
EOF
)
        curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$loki_url" >/dev/null

        # ---- 随時要求 ----
        send_req_e7e8

      # 定期動作の取得 定時積算電力量計測値 0xEA
      elif [[ "$data" =~ ^1081000102880105FF0173 ]]; then
        WAITING_REPLY=0
        LAST_RX_TIME=$now

        date_hex=${data:28:8}
        year=$((16#${date_hex:0:4}))
        month=$((16#${date_hex:4:2}))
        day=$((16#${date_hex:6:2}))

        time_hex=${data:36:6}
        hour=$((16#${time_hex:0:2}))
        minute=$((16#${time_hex:2:2}))
        second=$((16#${time_hex:4:2}))

        cum_energy_hex=${data:42:8}
        cum_energy=$((16#$cum_energy_hex))

        epoch_time=$(date -d "$(printf "%04d-%02d-%02d %02d:%02d:%02d" \
          $year $month $day $hour $minute $second)" +%s%N)

        echo "<== Energy=$cum_energy Wh"

        json_payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": { "job": "echonet-lite", "epc": "ea" },
      "values": [ [ "$epoch_time", "{\"value\": $cum_energy}" ] ]
    }
  ]
}
EOF
)
        curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$loki_url" >/dev/null

        # ---- 随時要求 ----
        send_req_e7e8
      fi
      ;;
  esac
done
