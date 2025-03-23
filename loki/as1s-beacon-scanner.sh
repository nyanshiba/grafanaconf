#!/bin/bash
# https://stackoverflow.com/a/52012231

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: must run as root"
    exit 1
fi

max_co2=900 # ppm (decimal)
sensor_id="00 FF" # Sensor 4095 (hex)
loki_url="http://loki.nuc.home.arpa:3100/loki/api/v1/push"

(cat <<'END' | /usr/bin/expect

    set sensor_address "00:53:FE:DC:BA:98"

    set prompt ">"
    set timeout -1

    spawn bluetoothctl

    expect -re $prompt
    send "scan off\r"

    expect -re $prompt
    send "remove *\r"

    expect -re $prompt
    send "menu scan\r"

    expect -re $prompt
    send "clear\r"

    expect -re $prompt
    send "transport le\r"

    expect -re $prompt
    send "duplicate-data on\r"

    expect -re $prompt
    send "pattern $sensor_address\r"

    expect -re $prompt
    send "back\r"

    expect -re $prompt
    send "scan on\r"

    trap {
        expect -re $prompt
        send "scan off\r"

        expect -re $prompt
        send "remove *\r"

        expect -re $prompt
        send "quit\r"
    } SIGINT

    expect eof

END
# low battery warning: a1 sensor_id 00 02 a3 07 d7 09 40 00 3c 01 2d
# fully charged      : a1 sensor_id 01 02 b1 07 c8 08 ec 00 0a 01 80
) | grep -oP --line-buffered "a1 $sensor_id 0\d \K(\w+\s){10}" | while read -r bytes; do
    # rate limit based on CO2
    if [ "${bytes:0:5}" != "${prev_bytes:0:5}" ]; then
        epoch_time=$(date +%s%N)

        air_list=()
        i=0
        
        for byte in $bytes; do
            if [ $i = 1 ]; then
                air_list+=($((16#$prev_byte$byte)))
                i=0
            else
                prev_byte=$byte
                i=1
            fi
        done

        celsius_temp=`echo ${air_list[1]} | sed 's/..$/.&/'`
        humidity=`echo ${air_list[2]} | sed 's/..$/.&/'`
        batteryraw=`echo "$bytes" | sed 's/.* //'`
        battery=`echo $(((0x$batteryraw * 0x64) >> 7))`

        json_payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "label": "co2"
      },
      "values": [
        [ "$epoch_time", "${air_list[0]}" ]
      ]
    },
    {
      "stream": {
        "label": "celsius_temp"
      },
      "values": [
        [ "$epoch_time", "$celsius_temp" ]
      ]
    },
    {
      "stream": {
        "label": "humidity"
      },
      "values": [
        [ "$epoch_time", "$humidity" ]
      ]
    },
    {
      "stream": {
        "label": "battery"
      },
      "values": [
        [ "$epoch_time", "$battery" ]
      ]
    }
  ]
}
EOF
        )
        curl -X POST -H "Content-Type: application/json" -d "$json_payload" $loki_url

        prev_bytes=$bytes
    fi
done
