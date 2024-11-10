#!/bin/bash
loki_url="http://loki.nuc.home.arpa:3100/loki/api/v1/push"

# unbound-control statsから必要なキーとtimestampを取得
stats=$(/usr/local/sbin/unbound-control stats)
timestamp="$(echo "$stats" | grep "^time.now=" | cut -d'=' -f2 | sed 's/\.//')000"  # "1731150071.526840" -> "1731150071526840000" に変換

# 取得したいキーとラベル名をマッピング
declare -A labels=(
    ["num.query.type.A"]="\"qtype\": \"a\""
    ["num.query.type.AAAA"]="\"qtype\": \"aaaa\""
    ["num.query.type.SVCB"]="\"qtype\": \"svcb\""
    ["num.query.type.HTTPS"]="\"qtype\": \"https\""
    ["num.answer.rcode.NOERROR"]="\"rcode\": \"noerror\""
    ["num.answer.rcode.SERVFAIL"]="\"rcode\": \"servfail\""
    ["num.answer.rcode.NXDOMAIN"]="\"rcode\": \"nxdomain\""
    ["num.answer.rcode.REFUSED"]="\"rcode\": \"refused\""
    ["num.answer.rcode.nodata"]="\"rcode\": \"nodata\""
    ["rrset.cache.count"]="\"cache\": \"rrset\""
)

# JSON形式のデータを生成
payload="{\"streams\": ["

for key in "${!labels[@]}"; do
    value=$(echo "$stats" | grep "^$key=" | cut -d'=' -f2)
    label=${labels[$key]}
    payload+="{\"stream\": {\"job\": \"unbound-stats\", ${label}}, \"values\": [[\"${timestamp}\", \"${value}\"]]},"
done

# 末尾のカンマを削除してJSONを閉じる
payload="${payload%,} ]}"
# echo $payload

# データをLokiに送信
curl -X POST -H "Content-Type: application/json" -d "$payload" "$loki_url"
