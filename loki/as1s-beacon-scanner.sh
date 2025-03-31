#!/bin/bash
# https://stackoverflow.com/a/52012231

sensor_id="0F FF" # Sensor 4095 (hex)
loki_url="http://loki.home.arpa:3100/loki/api/v1/push"

(cat <<'END' | /usr/bin/expect

    set prompt ">"
    set timeout -1

    spawn bluetoothctl

    expect -re $prompt
    send "menu monitor\r"

    expect -re $prompt
    send "add-or-pattern 0 255 6509\r"

    trap {
        expect -re $prompt
        send "remove-pattern all\r"

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

        # cf. https://komoriss.com/relative-humidity-volumetric-humidity/
        e=$(awk "BEGIN {print 6.1078 * (10 ^ ((7.5 * $celsius_temp) / (237.3 + $celsius_temp)))}")
        a=$(awk "BEGIN {print (217 * $e) / ($celsius_temp + 273.15)}")
        volumetric_humidity=$(awk "BEGIN {print $a * ($humidity / 100)}")

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
        "label": "volumetric_humidity"
      },
      "values": [
        [ "$epoch_time", "$volumetric_humidity" ]
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
