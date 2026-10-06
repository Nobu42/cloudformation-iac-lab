# インフラ設計書（AWS Webアプリケーション基盤）

## 1. 目的

本設計書は、AWS上にWebアプリケーション基盤を構築するためのネットワーク、サーバー、データベース、DNS、メール関連リソースの構成を定義する。

本構成は学習用環境を前提とし、AWS CLIとシェルスクリプトで構築した内容をもとに、後続でTerraform化することを目的とする。

## 2. システム概要

- Public SubnetにALB、NAT Gateway、踏み台サーバーを配置する
- Private SubnetにWebサーバーを配置する
- WebサーバーはPublic IPを持たず、踏み台サーバー経由で管理する
- ALBからPrivate Subnet上のWebサーバーへHTTP 3000番で転送する
- RDS for MySQLはPrivate Subnetを利用したDB Subnet Groupに配置する
- S3をアプリケーションのアップロード先として利用する
- Route 53でPublic DNSとPrivate DNSを管理する
- ACM証明書を利用してALBをHTTPS化する
- SESでメール送信とメール受信を検証する
- ElastiCache for RedisをPrivate Subnetに配置し、Webサーバーからのキャッシュ利用を検証する
- 学習終了後は削除スクリプトで課金対象リソースを削除する

## 3. VPC設計

### 3.1 VPC設定

| 項目 | 設定値 |
| :--- | :--- |
| Name Tag | sample-vpc |
| IPv4 CIDR | 10.0.0.0/16 |
| Tenancy | default |
| DNS Hostnames | enabled |
| DNS Support | enabled |

### 3.2 サブネット設計

| 区分 | サブネット名 | AZ | CIDR | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| Public | sample-subnet-public01 | ap-northeast-1a | 10.0.0.0/20 | ALB / NAT Gateway / Bastion |
| Public | sample-subnet-public02 | ap-northeast-1c | 10.0.16.0/20 | ALB / NAT Gateway |
| Private | sample-subnet-private01 | ap-northeast-1a | 10.0.64.0/20 | Web/AP / RDS Subnet Group / ElastiCache Subnet Group |
| Private | sample-subnet-private02 | ap-northeast-1c | 10.0.80.0/20 | Web/AP / RDS Subnet Group / ElastiCache Subnet Group |


### 3.3 インターネット接続

| リソース | 名前 | 接続先 |
| :--- | :--- | :--- |
| Internet Gateway | sample-igw | sample-vpc |

### 3.4 NAT Gateway

| 名前 | 配置サブネット | AZ | 用途 |
| :--- | :--- | :--- | :--- |
| sample-ngw-01 | sample-subnet-public01 | ap-northeast-1a | Private Subnet 01からの外向き通信 |
| sample-ngw-02 | sample-subnet-public02 | ap-northeast-1c | Private Subnet 02からの外向き通信 |

### 3.5 ルートテーブル

| 名前 | 対象 | ルート | 関連サブネット |
| :--- | :--- | :--- | :--- |
| sample-rt-public | Public | 0.0.0.0/0 → sample-igw | public01, public02 |
| sample-rt-private01 | Private | 0.0.0.0/0 → sample-ngw-01 | private01 |
| sample-rt-private02 | Private | 0.0.0.0/0 → sample-ngw-02 | private02 |

## 4. セキュリティ設計

### 4.1 セキュリティグループ

| 名前 | 用途 | インバウンド | 送信元 |
| :--- | :--- | :--- | :--- |
| sample-sg-bastion | 踏み台サーバー | SSH 22/tcp | 自分のグローバルIP /32 |
| sample-sg-elb | ALB | HTTP 80/tcp | 0.0.0.0/0 |
| sample-sg-elb | ALB | HTTPS 443/tcp | 0.0.0.0/0 |
| sample-sg-web | Webサーバー | SSH 22/tcp | sample-sg-bastion |
| sample-sg-web | Webサーバー | App 3000/tcp | sample-sg-elb |
| sample-sg-db | RDS | MySQL 3306/tcp | sample-sg-web |
| sample-sg-elasticache | ElastiCache Redis | Redis 6379/tcp | sample-sg-web |

### 4.2 基本方針

- WebサーバーはPrivate Subnetに配置し、Public IPを付与しない
- WebサーバーへのSSHは踏み台サーバー経由のみ許可する
- WebサーバーのアプリケーションポートはALBからのみ許可する
- RDSはWebサーバー用Security Groupからのみ接続を許可する
- BastionのSSH接続元は実行時に取得した自分のグローバルIPに制限する

## 5. EC2設計

### 5.1 共通設定

| 項目 | 値 |
| :--- | :--- |
| AMI | Amazon Linux 2023 latest AMI |
| sample-ec2-bastion | t3.micro |
| sample-ec2-web01 | t3.small |
| sample-ec2-web02 | t3.small |
| Key Pair | nobu |
| OSユーザー | ec2-user |

### 5.2 サーバー一覧

| 名前 | AZ | サブネット | Public IP | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| sample-ec2-bastion | ap-northeast-1a | sample-subnet-public01 | あり | 踏み台サーバー |
| sample-ec2-web01 | ap-northeast-1a | sample-subnet-private01 | なし | Web/AP |
| sample-ec2-web02 | ap-northeast-1c | sample-subnet-private02 | なし | Web/AP |

## 6. ロードバランサー設計

### 6.1 ALB

| 項目 | 内容 |
| :--- | :--- |
| 名前 | sample-elb |
| 種別 | Application Load Balancer |
| スキーム | internet-facing |
| サブネット | sample-subnet-public01, sample-subnet-public02 |
| Security Group | sample-sg-elb |

### 6.2 Target Group

| 項目 | 内容 |
| :--- | :--- |
| 名前 | sample-tg |
| プロトコル | HTTP |
| ポート | 3000 |
| ターゲット | sample-ec2-web01, sample-ec2-web02 |
| ヘルスチェックパス | / |

### 6.3 Listener

| Protocol | Port | Default Action |
| :--- | :--- | :--- |
| HTTP | 80 | forward → sample-tg |
| HTTPS | 443 | forward → sample-tg |

HTTPS Listenerでは、ACMで発行した `www.nobu-iac-lab.com` の証明書を利用する。

## 7. RDS設計

### 7.1 基本構成

| 項目 | 値 |
| :--- | :--- |
| DB識別子 | sample-db |
| エンジン | MySQL 8.0 |
| インスタンスクラス | db.t3.micro |
| 配置 | Private Subnet |
| Publicly Accessible | false |
| Multi-AZ | false |
| Backup Retention | 0 |
| Port | 3306 |

学習環境のため、現時点ではMulti-AZを無効としている。
可用性設計の検証時にMulti-AZ化を検討する。

### 7.2 DB関連リソース

| 種別 | 名前 |
| :--- | :--- |
| DB Parameter Group | sample-db-pg |
| DB Option Group | sample-db-og |
| DB Subnet Group | sample-db-subnet |
| DB Security Group | sample-sg-db |

### 7.3 DB Subnet Group

| 名前 | サブネット |
| :--- | :--- |
| sample-db-subnet | sample-subnet-private01, sample-subnet-private02 |

## 8. S3設計

### 8.1 アプリケーション用S3

| 項目 | 値 |
| :--- | :--- |
| バケット名 | nobu-terraform-iac-lab-upload |
| 用途 | Webアプリケーションからのファイルアップロード検証 |
| Public Access Block | 有効 |
| ACL | 無効 |
| EC2からのアクセス | IAM Role sample-role-web |

### 8.2 SES受信用S3

| 項目 | 値 |
| :--- | :--- |
| バケット名 | nobu-iac-lab-mailbox |
| 用途 | SESで受信したメールの保存 |
| 保存プレフィックス | inbox/ |
| Public Access Block | 有効 |
| ACL | 無効 |

受信メールはraw MIME形式でS3に保存する。

## 9. IAM設計

### 9.1 Web EC2用IAM Role

| 項目 | 値 |
| :--- | :--- |
| Role名 | sample-role-web |
| Instance Profile | sample-role-web |
| 用途 | Web EC2からS3へアクセス |
| 付与ポリシー | AmazonS3FullAccess |

学習用のためAWS管理ポリシーを使用している。
実運用では対象バケットに限定した最小権限ポリシーを検討する。

### 9.2 SES SMTP用IAM User

| 項目 | 値 |
| :--- | :--- |
| ユーザー名 | ses-smtp-no-reply |
| 用途 | SES SMTP認証 |
| 利用方法 | SMTP Username / SMTP Passwordを環境変数で利用 |

SMTP認証情報は秘密情報であるため、リポジトリには保存しない。

## 10. DNS設計

### 10.1 Public DNS

| レコード | タイプ | ルーティング先 |
| :--- | :--- | :--- |
| bastion.nobu-iac-lab.com | A | Bastion Public IP |
| www.nobu-iac-lab.com | A Alias | sample-elb |
| nobu-iac-lab.com | MX | inbound-smtp.ap-northeast-1.amazonaws.com |

`bastion` と `www` は日次構築時に作成し、削除時に削除する。
MXレコードはSES受信を行う時だけ作成し、削除時に削除する。

### 10.2 Private DNS

| レコード | タイプ | ルーティング先 |
| :--- | :--- | :--- |
| bastion.home | A | Bastion Private IP |
| web01.home | A | Web01 Private IP |
| web02.home | A | Web02 Private IP |
| db.home | CNAME | RDS Endpoint |

Private Hosted Zone `home` は `sample-vpc` に関連付ける。

## 11. ACM設計

| 項目 | 値 |
| :--- | :--- |
| 証明書対象 | www.nobu-iac-lab.com |
| 検証方式 | DNS検証 |
| DNS管理 | Route 53 |
| 利用先 | ALB HTTPS Listener |

ACM証明書は無料で利用できるため、削除スクリプトでは削除せず再利用する。

## 12. SES設計

### 12.1 送信設定

| 項目 | 値 |
| :--- | :--- |
| Domain Identity | nobu-iac-lab.com |
| DKIM | Easy DKIM |
| SPF | v=spf1 include:amazonses.com ~all |
| DMARC | v=DMARC1; p=none; rua=mailto:<verified-email> |
| テスト送信先 | 検証済みメールアドレス |
| From | no-reply@nobu-iac-lab.com |

### 12.2 受信設定

| 項目 | 値 |
| :--- | :--- |
| 受信アドレス | inquiry@nobu-iac-lab.com |
| Receipt Rule Set | sample-ruleset |
| Receipt Rule | sample-rule-inquiry |
| Spam and virus scanning | enabled |
| 保存先S3 | nobu-iac-lab-mailbox/inbox/ |

## 13. ElastiCache設計

### 13.1 基本構成

| 項目 | 値 |
| :--- | :--- |
| Replication Group ID | sample-elasticache |
| エンジン | Redis |
| クラスターモード | enabled |
| ノードタイプ | cache.t3.micro |
| シャード数 | 2 |
| シャードあたりのレプリカ数 | 2 |
| 合計ノード数 | 6 |
| 配置 | Private Subnet |
| Port | 6379 |

学習環境ではRedis Cluster構成を確認するため、クラスターモード有効、2シャード、各シャード2レプリカで作成する。

### 13.2 ElastiCache関連リソース

| 種別 | 名前 |
| :--- | :--- |
| Replication Group | sample-elasticache |
| Cache Subnet Group | sample-elasticache-sg |
| Security Group | sample-sg-elasticache |

### 13.3 通信設計

| 接続元 | 接続先 | Port | 用途 |
| :--- | :--- | :--- | :--- |
| sample-sg-web | sample-sg-elasticache | 6379/tcp | WebサーバーからRedisへの接続 |

ElastiCacheはPrivate Subnetに配置し、Webサーバー用Security GroupからのみRedisポートへの接続を許可する。

## 14. 運用設計

### 14.1 日次学習時の構築方針

学習時のみAWSリソースを作成し、学習終了後に削除する。

毎回作成する主なリソース:

- VPC
- Subnet
- IGW
- NAT Gateway
- Route Table
- Security Group
- EC2
- ALB
- RDS
- S3
- Private Hosted Zone
- Public DNS一時レコード
- SES受信用S3 / Receipt Rule / MX
- ElastiCache
- ElastiCache Subnet Group
- ElastiCache Security Group

残すリソース:

- ドメイン登録
- Public Hosted Zone
- ACM証明書
- ACM DNS検証用CNAME
- SES Domain Identity
- DKIM / SPF / DMARC
- SES SMTP IAM User

### 14.2 削除運用

学習終了後は `cleanup_all.sh` を実行する。

削除後は `check_cleanup.sh` で以下を確認する。

- EC2が残っていないこと
- NAT Gatewayが `available` で残っていないこと
- Elastic IPが残っていないこと
- ALB / Target Groupが残っていないこと
- RDSが残っていないこと
- S3バケットが残っていないこと
- Public DNSの一時レコードが残っていないこと
- Private Hosted Zoneが残っていないこと
- ElastiCache Replication Groupが残っていないこと
- ElastiCache Subnet Groupが残っていないこと

## 15. 非機能要件

### 可用性

- ALBは2つのPublic Subnetに配置する
- Webサーバーは2つのAZに分散する
- NAT Gatewayは各AZに配置する
- RDSは現時点ではSingle-AZとし、今後Multi-AZ化を検討する
- ElastiCacheは2シャード、各シャード2レプリカで構成する

### セキュリティ

- WebサーバーはPrivate Subnetに配置する
- RDSはPublicly Accessibleを無効にする
- SSHはBastion経由に限定する
- BastionへのSSHは自分のグローバルIPに制限する
- S3はPublic Access Blockを有効化する
- SMTP認証情報やDBパスワードはリポジトリに保存しない

### 運用

- コスト確認スクリプトで利用料金を確認する
- 削除スクリプトで課金対象リソースを削除する
- CloudWatchによる監視は今後追加する
- Terraform化後は差分確認と再現性を高める

## 16. 今後の拡張

- AnsibleによるWebサーバー内部設定の自動化
- Railsアプリケーションのデプロイ
- CloudWatch Logs / Metrics / Alarm
- Terraform化
- Auto Scaling Group
- ECS / Fargate
- CodePipelineまたはGitHub Actions

