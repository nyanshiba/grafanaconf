#!/bin/bash

DEVICE="/dev/ttyUSB0"
PAWD="0123456789AB"
RBID="00112233445566778899AABBCCDDEEFF"
CHANNEL="21" # SKSCAN Channel:
PANID="8888" # SKSCAN Pan ID:
IPADDR="FE80:0000:0000:0000:1034:5678:ABCD:EF02" # SKLL64 <Addr>
SIDE="0"
loki_url="http://loki.home.arpa:3100/loki/api/v1/push"

INTERVAL=30        # 通常送信間隔（秒）
TIMEOUT=10         # 応答待ちタイムアウト
MAX_RETRY=3

# ===== 初期化 =====
stty -F "$DEVICE" 115200 raw -echo -icrnl -onlcr

JOINING=0
JOINED=0
RETRY=0

WAITING_REPLY=0
LAST_SEND_TIME=0
RETRY_COUNT=0

# ===== 関数 =====

send_join() {
    if [[ ${JOINING:-0} -eq 1 ]]; then
        return
    fi

    JOINING=1
    echo "==> SKJOIN"
    echo -e "SKJOIN $IPADDR\r\n" > "$DEVICE"
}

backoff() {
    # https://echonet.jp/spec_g/#standard-03 6.11
    sleep_time=$((2 ** RETRY))
    [ $sleep_time -gt 60 ] && sleep_time=60
    echo "Backoff: ${sleep_time}s"
    sleep $sleep_time
    RETRY=$((RETRY + 1))
}

send_request() {
    echo "==> SEND REQUEST"

    {
        printf "SKSENDTO 1 $IPADDR 0E1A 1 ${SIDE} 0012 "
        printf '\x10\x81\x00\x01\x05\xff\x01\x02\x88\x01\x62\x02\xe7\x00\xe8\x00'
        printf '\r\n'
    } > "$DEVICE"

    WAITING_REPLY=1
    LAST_SEND_TIME=$(date +%s)
}

cleanup() {
    echo -e "SKTERM\r\n" > "$DEVICE"
}
trap cleanup EXIT INT TERM

# ===== 初期設定 =====
echo -e "SKERASE\r\n" > "$DEVICE"
sleep 1
{
    echo -e "SKSETPWD C $PAWD\r\n"
    echo -e "SKSETRBID $RBID\r\n"
    echo -e "SKSREG S2 $CHANNEL\r\n" # 親機のチャンネルに合わせる
    echo -e "SKSREG S3 $PANID\r\n" # PAN IDを合わせる
} > "$DEVICE"

send_join # PAAへ接続開始

# ===== メインループ =====
while true; do

    # ---- 非同期受信 ----
    if read -t 1 -r line < "$DEVICE"; then
        echo "$line"

        case "$line" in

            # PANA認証失敗
            *"EVENT 24"*)
                echo "JOIN FAILED"
                JOINING=0
                JOINED=0
                backoff
                send_join
                ;;

            # PANA認証成功
            *"EVENT 25"*)
                echo "JOIN SUCCESS"
                JOINING=0
                JOINED=1
                RETRY=0
                ;;

            # セッション終了
            *"EVENT 28"*)
                echo "SESSION LOST"
                JOINING=0our
                JOINED=0
                backoff
                send_join
                ;;

            *"ERXUDP"*)
                [ "$JOINED" -eq 0 ] && continue

                data=$(echo "$line" | awk '{print $NF}')

                # ===== E7/E8 応答 =====
                if [[ "$data" =~ ^1081000102880105FF0172 ]]; then

                    WAITING_REPLY=0
                    RETRY_COUNT=0

                    # EPC: 0xE7 瞬時電力計測値
                    inst_power=$((16#${data:28:8}))

                    # EPC: 0xE8 瞬時電流計測値
                    raw_r=$((16#${data:40:4}))
                    inst_current_phase_r="${raw_r%?}.${raw_r: -1}"
                    raw_t=$((16#${data:44:4}))
                    inst_current_phase_t="${raw_t%?}.${raw_t: -1}"

                    epoch_time=$(date +%s%N)

                    echo "Power=$inst_power W  R=$inst_current_phase_r A  T=$inst_current_phase_t A"
                    json_payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "job": "echonet-lite",
        "epc": "e7"
      },
      "values": [
        [ "$epoch_time", "{\"value\": $inst_power}" ]
      ]
    },
    {
      "stream": {
        "job": "echonet-lite",
        "epc": "e8",
        "phase": "r"
      },
      "values": [
        [ "$epoch_time", "{\"value\": $inst_current_phase_r}" ]
      ]
    },
    {
      "stream": {
        "job": "echonet-lite",
        "epc": "e8",
        "phase": "t"
      },
      "values": [
        [ "$epoch_time", "{\"value\": $inst_current_phase_t}" ]
      ]
    }
  ]
}
EOF
                    )
                    #echo $json_payload
                    curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" $loki_url

                # ===== EA 定時積算 =====
                elif [[ "$data" =~ ^1081000102880105FF0173 ]]; then

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

                    echo "Energy=$cum_energy Wh"
                    json_payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "job": "echonet-lite",
        "epc": "ea"
      },
      "values": [
        [ "$epoch_time", "{\"value\": $cum_energy}" ]
      ]
    }
  ]
}
EOF
                    )
                    # echo $json_payload
                    curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" $loki_url

                fi
                ;;
        esac
    fi

    # ---- タイムアウト再送 ----
    now=$(date +%s)

    if [[ $JOINED -eq 1 && $WAITING_REPLY -eq 1 ]]; then
        if (( now - LAST_SEND_TIME > TIMEOUT )); then
            echo "TIMEOUT"

            if (( RETRY_COUNT < MAX_RETRY )); then
                RETRY_COUNT=$((RETRY_COUNT + 1))
                send_request
            else
                echo "RETRY LIMIT → REJOIN"
                WAITING_REPLY=0
                send_join
            fi
        fi
    fi

    # ---- 定期送信 ----
    if [[ $JOINED -eq 1 && $WAITING_REPLY -eq 0 ]]; then
        if (( now - LAST_SEND_TIME > INTERVAL )); then
            send_request
        fi
    fi

done
