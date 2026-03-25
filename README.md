## Loki

### as1s-beacon-scanner.sh

旭化成 3密見える化センサの温度, 湿度, CO2値をGrafanaに表示するために、BLEビーコンをスキャンしてLokiに送るシェルスクリプト。  
[3密見える化センサのCO2値をプッシュ通知する - 俺の外付けHDD](https://nyanshiba.com/blog/co2-via-ble/#bluetoothctl)

### broute-exporter.sh

L7023 Stick-D/DSSでBルートから消費電力を取得するシェルスクリプト。  
低圧スマート電力量メータから低圧瞬時電力計測値0xE7, 瞬時電流計測値0xE8, 定時積算電力量 計測値0xEAを取得できる。

### mspt-exporter.sh

MinecraftのMSPTを取得するシェルスクリプト。  
[可視化はGrafanaでって言ったよね - 俺の外付けHDD](https://nyanshiba.com/blog/grafana/#minecraft)

### oura-exporter.ps1

[Oura API V2](https://cloud.ouraring.com/v2/docs#operation/Multiple_daily_readiness_Documents_v2_usercollection_daily_readiness_get)を叩いて整形してLokiに送るPowerShellスクリプト。

### sflow-collector.sh

NEC IX2000/3000シリーズのsFlow フローサンプルをGrafanaに表示するために、sFlow Collectorとして振る舞うシェルスクリプト。  
[UNIVERGE IX2215で、ひかり電話のない環境にデュアルスタックVLANをつくる - 俺の外付けHDD](https://nyanshiba.com/blog/nec-ix/#sflow)

### unbound-stats.sh

unbound-controlのextended-statisticsを使って、QTYPEやRCODEを収集するシェルスクリプト。  
[Unboundでお手軽DNSシンクホール - 俺の外付けHDD](https://nyanshiba.com/blog/unbound/#unbound-control-stats)
