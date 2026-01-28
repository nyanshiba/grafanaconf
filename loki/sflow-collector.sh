#!/bin/bash
loki_url="http://loki.home.arpa:3100/loki/api/v1/push"
if_wan=1 # GigaEthernet0
ip4_suffix_regex='s/^(\w+.){2}(.*)$/\2/' # 10.0.1.2 -> 1.2
ip6_suffix_regex='s/^\w+(:\w+){3}(\w.*)$/\2/' # 2001:db8:b0ba:10ee:: -> e::

function sampling_rate_to_factor() {
  # bytes/s -> bits/10s
  echo $(($1 * 8 / 10))
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

goflow -kafka=false -logfmt=json -nf=false | while read -r line; do
  read -r time_received sampling_rate bytes src_addr dst_addr eth_type in_if out_if src_mac tci iptos ipttl < <(
    echo "$line" | jq -r '[.TimeReceived, .SamplingRate, .Bytes, .SrcAddr, .DstAddr, .Etype, .InIf, .OutIf, .SrcMac, .VlanId, .IPTos, .IPTTL] | @tsv'
  )

  # フローサンプルを加算
  # 下り
  if [ "$in_if" == "$if_wan" ]; then
    bytes_in=$((bytes_in + bytes))
    factor_in=`sampling_rate_to_factor $sampling_rate`
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
    factor_local=`sampling_rate_to_factor $sampling_rate`
    vid_local=`tci_to_vid $tci`
    src_addr_local=`addr_to_suffix $src_addr $eth_type`
    # echo "DEBUG $in_if $out_if $bytes_local $factor_local $vid_local $src_addr_local"
  # たぶん上り
  else
    bytes_out=$((bytes_out + bytes))
    factor_out=`sampling_rate_to_factor $sampling_rate`
    vid_out=`tci_to_vid $tci`
    src_addr_out=`addr_to_suffix $src_addr $eth_type $src_mac`
    dst_addr_out="$dst_addr"

    # ToS値をマークダウンし忘れたパケット
    if [ "$iptos" != "0" ]; then
      iptos_out="$iptos"
    fi
    # echo "DEBUG $in_if $out_if $bytes_out $factor_out $vid_out $src_addr_out $dst_addr_out $iptos_out"
  fi

  # 10秒ごとにLokiに送信 trrafic bits/s = Bytes * 8bits * 2000samples / 10sec
  # time_received_100s="${time_received%??}00000000000"
  time_received_10s="${time_received%?}0000000000"

  if [ "$time_received_10s" != "$prev_time_received_10s" ]; then

    payload=$(jq -n \
      --arg bytes_in "$bytes_in" \
      --arg factor_in "$factor_in" \
      --arg eth_type_in "$eth_type_in" \
      --arg src_addr_in "$src_addr_in" \
      --arg dst_addr_in "$dst_addr_in" \
      --arg ipttl_in "$ipttl_in" \
      --arg iptos_in "$iptos_in" \
      --arg bytes_local "$bytes_local" \
      --arg factor_local "$factor_local" \
      --arg vid_local "$vid_local" \
      --arg src_addr_local "$src_addr_local" \
      --arg bytes_out "$bytes_out" \
      --arg factor_out "$factor_out" \
      --arg vid_out "$vid_out" \
      --arg src_addr_out "$src_addr_out" \
      --arg dst_addr_out "$dst_addr_out" \
      --arg iptos_out "$iptos_out" \
      --arg time_received_ns "$time_received_10s" '
      {
        "streams": [
          {
            "stream": { "job": "goflow", "factor": $factor_in, "direction": "in", "eth_type": $eth_type_in, "src_addr": $src_addr_in, "dst_addr": $dst_addr_in, "ipttl": $ipttl_in, "iptos": $iptos_in },
            "values": [ [$time_received_ns, $bytes_in] ]
          },
          {
            "stream": { "job": "goflow", "factor": $factor_local, "direction": "vlan", "vid": $vid_local, "src_addr": $src_addr_local },
            "values": [ [$time_received_ns, $bytes_local] ]
          },
          {
            "stream": { "job": "goflow", "factor": $factor_out, "direction": "out", "vid": $vid_out, "src_addr": $src_addr_out, "dst_addr": $dst_addr_out, "iptos": $iptos_out },
            "values": [ [$time_received_ns, $bytes_out] ]
          }
        ]
      }
    ')

    curl -X POST -H "Content-Type: application/json" -d "$payload" "$loki_url"
    # echo "DEBUG Sent data to Loki: $payload"

    prev_time_received_10s=$time_received_10s
    bytes_in=0
    factor_in=""
    eth_type_in=""
    src_addr_in=""
    dst_addr_in=""
    ipttl_in=""
    iptos_in=""
    bytes_local=0
    factor_local=""
    vid_local=""
    src_addr_local=""
    bytes_out=0
    factor_out=""
    vid_out=""
    src_addr_out=""
    dst_addr_out=""
    iptos_out=""
    time_received_ns=""
  fi
done
