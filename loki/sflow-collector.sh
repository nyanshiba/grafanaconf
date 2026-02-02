#!/bin/bash
loki_url="http://loki.home.arpa:3100/loki/api/v1/push"
send_rate=31 # 0で全てのフローサンプルを送る
if_wan=1 # GigaEthernet0
ip4_suffix_regex='s/^(\w+.){2}(.*)$/\2/' # 10.0.1.2 -> 1.2
ip6_suffix_regex='s/^\w+(:\w+){3}(\w.*)$/\2/' # 2001:db8:b0ba:10ee:: -> e::

function sampling_rate_to_factor() {
  # bytes/s -> bits/Xs
  echo $(($1 * 8 / ($2 - $3)))
}

function addr_to_suffix() {
  if [ "$2" == "34525" ]; then
    # IPv6はsrc_macを優先
    if [ -n "$3" ]; then
      echo $3
    else
      echo $(echo "$1" | sed -r $ip6_suffix_regex)
    fi
  else # 2048, 2054, 34916, etc.
    echo $(echo "$1" | sed -r $ip4_suffix_regex)
  fi
}

function tci_to_vid() {
  echo $(( $1 & 0x0fff ))
}

cnt=1
prev_time_received=`date +%s`
goflow -kafka=false -logfmt=json -nf=false | while read -r line; do
  read -r time_received sampling_rate bytes src_addr dst_addr eth_type in_if out_if src_mac tci iptos ipttl < <(
    echo "$line" | jq -r '[.TimeReceived, .SamplingRate, .Bytes, .SrcAddr, .DstAddr, .Etype, .InIf, .OutIf, .SrcMac, .VlanId, .IPTos, .IPTTL] | @tsv'
  )

  # フローサンプルを加算
  # 下り
  if [ "$in_if" == "$if_wan" ]; then
    bytes_in=$((bytes_in + bytes))
    # decimal to hex
    eth_type_in=`printf '0x%x\n' $eth_type`

    # 0x8864 PPPoE SessionはIPが<nil>
    if [ "$eth_type" != "34916" ]; then
      src_addr_in="$src_addr"
      dst_addr_in=`addr_to_suffix $dst_addr $eth_type`

      # 0, tracerouteを除外してHop Limitを記録
      if [ $ipttl -gt 30 ]; then
        ipttl_in="$ipttl"
      fi

      # ToS値が0でない、網側からの特殊パケット
      if [ "$iptos" != "0" ]; then
        iptos_in="$iptos"
      fi
    fi
    # echo "DEBUG $in_if $out_if $bytes_in $factor_in $eth_type_in $src_addr_in $dst_addr_in $ipttl_in $iptos_in"
  # VLAN間 0x3FFFFFFF: IXの自生成パケット
  elif [ "$out_if" != "$if_wan" ] && [ "$out_if" != "1073741823" ]; then
    bytes_local=$((bytes_local + bytes))
    vid_local=`tci_to_vid $tci`
    src_addr_local=`addr_to_suffix $src_addr $eth_type`
    # echo "DEBUG $in_if $out_if $bytes_local $factor_local $vid_local $src_addr_local"
  # たぶん上り
  else
    bytes_out=$((bytes_out + bytes))
    vid_out=`tci_to_vid $tci`
    src_addr_out=`addr_to_suffix $src_addr $eth_type $src_mac`
    dst_addr_out="$dst_addr"

    # ToS値をマークダウンし忘れたパケット
    if [ "$iptos" != "0" ]; then
      iptos_out="$iptos"
    fi
    # echo "DEBUG $in_if $out_if $bytes_out $factor_out $vid_out $src_addr_out $dst_addr_out $iptos_out"
  fi

  # 10秒 or send_rate or 100秒毎に送る
  if [ $cnt -gt $send_rate ] && [ "${time_received%?}" != "${prev_time_received%?}" ] || [ "${time_received%??}" != "${prev_time_received%??}" ]; then
    factor=`sampling_rate_to_factor $sampling_rate $time_received $prev_time_received`
    # echo "DEBUG $time_received $factor"

    payload=$(jq -n \
      --arg bytes_in "$bytes_in" \
      --arg factor "$factor" \
      --arg eth_type_in "$eth_type_in" \
      --arg src_addr_in "$src_addr_in" \
      --arg dst_addr_in "$dst_addr_in" \
      --arg ipttl_in "$ipttl_in" \
      --arg iptos_in "$iptos_in" \
      --arg bytes_local "$bytes_local" \
      --arg vid_local "$vid_local" \
      --arg src_addr_local "$src_addr_local" \
      --arg bytes_out "$bytes_out" \
      --arg vid_out "$vid_out" \
      --arg src_addr_out "$src_addr_out" \
      --arg dst_addr_out "$dst_addr_out" \
      --arg iptos_out "$iptos_out" \
      --arg time_received_ns "${time_received}000000000" '
      {
        "streams": [
          {
            "stream": { "job": "goflow", "factor": $factor, "direction": "in", "eth_type": $eth_type_in, "src_addr": $src_addr_in, "dst_addr": $dst_addr_in, "ipttl": $ipttl_in, "iptos": $iptos_in },
            "values": [ [$time_received_ns, $bytes_in] ]
          },
          {
            "stream": { "job": "goflow", "factor": $factor, "direction": "vlan", "vid": $vid_local, "src_addr": $src_addr_local },
            "values": [ [$time_received_ns, $bytes_local] ]
          },
          {
            "stream": { "job": "goflow", "factor": $factor, "direction": "out", "vid": $vid_out, "src_addr": $src_addr_out, "dst_addr": $dst_addr_out, "iptos": $iptos_out },
            "values": [ [$time_received_ns, $bytes_out] ]
          }
        ]
      }
    ')

    curl -X POST -H "Content-Type: application/json" -d "$payload" "$loki_url"
    # echo "DEBUG Sent data to Loki: $payload"

    cnt=1
    prev_time_received=$time_received
    time_received_ns=""
    factor=""

    bytes_in=0
    eth_type_in=""
    src_addr_in=""
    dst_addr_in=""
    ipttl_in=""
    iptos_in=""
    bytes_local=0
    vid_local=""
    src_addr_local=""
    bytes_out=0
    vid_out=""
    src_addr_out=""
    dst_addr_out=""
    iptos_out=""
  fi

  ((cnt++))
done
