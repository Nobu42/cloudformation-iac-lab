# cloudformation-iac-lab

自分で設計したAWS構成をCloudFormationで構築し、RDS・Redisのバージョンアップと、更新後のテンプレートとの整合を練習するためのリポジトリ。

## 構成図

`terraform-iac-lab`で使用している設計図をコピーしたもの。CloudFormation化の元となる設計で、現在のAWS環境や構築済みの状態を示すものではない。

[![ネットワーク構成図](./doc/network-diagrams/01-network.png)](./doc/network-diagrams/01-network.png)

- [ネットワーク構成図を拡大](./doc/network-diagrams/01-network.png)
- [NAT Gateway・外向き通信経路](./doc/network-diagrams/02-egress.png)
- [DNS・証明書・S3・メール連携](./doc/network-diagrams/03-services.png)
- [図の説明・SVG・再生成手順](./doc/network-diagrams/README.md)
- [設計仕様書](./doc/Design_Specification.md)
