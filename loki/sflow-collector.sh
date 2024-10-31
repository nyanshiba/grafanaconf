#!/bin/bash
loki_url="http://loki.nuc.home.arpa:3100/loki/api/v1/push"
if_wan=1 # 1: GigaEthernet0, 3: GigaEthernet2, 1073741823(0x3FFFFFFF): IXの自生成パケット
if_lan=3

bytes_in=0
bytes_local=0
bytes_out=0
goflow -kafka=false -logfmt=json -nf=false | while read -r line; do  
  # フローサンプルを加算して
  if [ "$(echo "$line" | jq -r '.InIf')" == "$if_wan" ]; then
    # 下り
    let bytes_in=$bytes_in+$(echo "$line" | jq -r '.Bytes')
  elif [ "$(echo "$line" | jq -r '.InIf')" == "$if_lan" ] && [ "$(echo "$line" | jq -r '.OutIf')" == "$if_lan" ]; then
    # ローカル
    let bytes_local=$bytes_local+$(echo "$line" | jq -r '.Bytes')
  else
    let bytes_out=$bytes_out+$(echo "$line" | jq -r '.Bytes')
  fi

  # 100秒ごとにLokiに送信 trrafic bits/s = Bytes * 8bits * 2000samples / 100sec
  time_received_100s=$(echo "$line" | jq -r '.TimeReceived' | sed 's/[0-9]\{2\}$//')

  if [ "$time_received_100s" != "$prev_time_received_100s" ]; then
    payload=$(jq -n --arg time_received_ns "${time_received_100s}00000000000" \
      --arg sampling_rate $(echo "$line" | jq -r '.SamplingRate') \
      --arg bytes_in $bytes_in \
      --arg bytes_local $bytes_local \
      --arg bytes_out $bytes_out '
      {
        "streams": [
          {
            "stream": { "job": "goflow", "sampling_rate": $sampling_rate, "wan": "in" },
            "values": [ [$time_received_ns, $bytes_in] ]
          },
          {
            "stream": { "job": "goflow", "sampling_rate": $sampling_rate, "lan": "in" },
            "values": [ [$time_received_ns, $bytes_local] ]
          },
          {
            "stream": { "job": "goflow", "sampling_rate": $sampling_rate, "wan": "out" },
            "values": [ [$time_received_ns, $bytes_out] ]
          }
        ]
      }
    ')

    curl -X POST -H "Content-Type: application/json" -d "$payload" "$loki_url"
    # echo "Sent data to Loki: $payload"

    prev_time_received_100s=$time_received_100s
    bytes_in=0
    bytes_local=0
    bytes_out=0
  fi
done
