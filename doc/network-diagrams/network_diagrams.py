"""添付されたAWS設計書から図を生成する。AWS APIは呼び出さない。"""

import base64
import os
import xml.etree.ElementTree as ET
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.database import ElasticacheForRedis, RDSMysqlInstance
from diagrams.aws.engagement import SES
from diagrams.aws.network import ElbApplicationLoadBalancer, InternetGateway, NATGateway, Route53
from diagrams.aws.security import ACM, IAMRole
from diagrams.aws.storage import S3
from diagrams.onprem.client import User, Users


OUT = Path(__file__).resolve().parent
FONT = os.environ.get("DIAGRAM_FONT", "Hiragino Sans")
BLUE = "#1674A5"
GREEN = "#188368"
PURPLE = "#7853A5"
GRAY = "#64717E"
GRAPH = {
    "fontname": FONT, "fontsize": "23", "fontcolor": "#20313D",
    "bgcolor": "white", "pad": "1.1", "nodesep": "2.0",
    "ranksep": "1.15", "splines": "spline", "compound": "true",
    "dpi": "150", "labelloc": "t", "labeljust": "l",
}
NODE = {"fontname": FONT, "fontsize": "12", "fontcolor": "#20313D"}
EDGE = {"fontname": FONT, "fontsize": "11", "color": BLUE,
        "fontcolor": "#20313D", "penwidth": "1.7", "arrowsize": "0.8"}


def group(label, fill="#F5F8FA", border="#B1BFCA"):
    return Cluster(label, graph_attr={
        "fontname": FONT, "fontsize": "15", "fontcolor": "#20313D",
        "bgcolor": fill, "color": border, "style": "rounded",
        "margin": "65", "penwidth": "1.4", "labeljust": "l",
    })


def figure(title, name, direction="TB"):
    return Diagram(title, filename=str(OUT / name), show=False,
                   outformat=["png", "svg"], direction=direction,
                   graph_attr=GRAPH, node_attr=NODE, edge_attr=EDGE)


def network():
    with figure("01  ネットワーク構成 / Web・管理・DB通信", "01-network"):
        visitor = Users("Web利用者\nインターネット")
        admin = User("管理者\n自分のグローバルIP /32")
        with group("AWS / 東京リージョン  ap-northeast-1", "#FFFFFF", "#7A8D9B"):
            with group("sample-vpc  |  10.0.0.0/16  |  DNS support / hostnames: enabled"):
                igw = InternetGateway("sample-igw\nインターネット接続")
                alb = ElbApplicationLoadBalancer(
                    "sample-elb  [単一のALB]\ninternet-facing / sample-sg-elb\n"
                    "配置: public01 + public02\n80 / 443 → sample-tg :3000")
                with group("ap-northeast-1a", "#FFFFFF"):
                    with group("sample-subnet-public01\n10.0.0.0/20", "#ECF8EF", "#68A97A"):
                        bastion = EC2("sample-ec2-bastion\nt3.micro / Public IPあり\nsample-sg-bastion")
                        nat1 = NATGateway("sample-ngw-01\n外向き通信は図02参照")
                    with group("sample-subnet-private01\n10.0.64.0/20", "#EDF5FD", "#6A9FC5"):
                        web1 = EC2("sample-ec2-web01\nt3.small / Public IPなし\nsample-sg-web")
                    nat1 >> Edge(style="invis") >> web1
                with group("ap-northeast-1c", "#FFFFFF"):
                    with group("sample-subnet-public02\n10.0.16.0/20", "#ECF8EF", "#68A97A"):
                        nat2 = NATGateway("sample-ngw-02\n外向き通信は図02参照")
                    with group("sample-subnet-private02\n10.0.80.0/20", "#EDF5FD", "#6A9FC5"):
                        web2 = EC2("sample-ec2-web02\nt3.small / Public IPなし\nsample-sg-web")
                    nat2 >> Edge(style="invis") >> web2
                with group("Private subnet groups  |  private01 + private02\n稼働AZ・ノード別配置は設計書に指定なし", "#F3F0FA", "#A08AC0"):
                    db = RDSMysqlInstance("sample-db\nMySQL 8.0 / db.t3.micro\nSingle-AZ / 非公開\nsample-db-subnet / sample-sg-db")
                    redis = ElasticacheForRedis("sample-elasticache\ncache.t3.micro / Cluster有効\n2シャード × (Primary 1 + Replica 2)\n合計6ノード / sample-sg-elasticache")

                igw >> Edge(label="HTTP 80 / HTTPS 443") >> alb
                igw >> Edge(label="SSH 22", color=GREEN) >> bastion
                alb >> Edge(label="HTTP 3000\nsample-tg") >> web1
                alb >> Edge(label="HTTP 3000") >> web2
                bastion >> Edge(label="SSH 22", color=GREEN) >> web1
                bastion >> Edge(label="SSH 22", color=GREEN, constraint="false") >> web2
                web1 >> Edge(label="MySQL 3306") >> db
                web2 >> Edge(color=BLUE) >> db
                web1 >> Edge(label="Redis 6379", color=PURPLE) >> redis
                web2 >> Edge(color=PURPLE) >> redis
        visitor >> Edge(label="Webアクセス") >> igw
        admin >> Edge(label="SSH / 接続元を限定", color=GREEN) >> igw


def routes():
    with figure("02  外向き通信 / AZごとのNAT Gatewayとルート", "02-egress", "LR"):
        with group("AWS / ap-northeast-1  |  sample-vpc  10.0.0.0/16"):
            with group("ap-northeast-1a", "#FFFFFF"):
                with group("sample-subnet-private01  |  10.0.64.0/20", "#EDF5FD"):
                    web1 = EC2("sample-ec2-web01\nPublic IPなし\nsample-rt-private01")
                with group("sample-subnet-public01  |  10.0.0.0/20", "#ECF8EF"):
                    nat1 = NATGateway("sample-ngw-01\nsample-rt-public")
                web1 >> Edge(label="0.0.0.0/0\n→ sample-ngw-01", color=GREEN) >> nat1
            with group("ap-northeast-1c", "#FFFFFF"):
                with group("sample-subnet-private02  |  10.0.80.0/20", "#EDF5FD"):
                    web2 = EC2("sample-ec2-web02\nPublic IPなし\nsample-rt-private02")
                with group("sample-subnet-public02  |  10.0.16.0/20", "#ECF8EF"):
                    nat2 = NATGateway("sample-ngw-02\nsample-rt-public")
                web2 >> Edge(label="0.0.0.0/0\n→ sample-ngw-02", color=GREEN) >> nat2
            igw = InternetGateway("sample-igw\nPublic用ルートテーブルは共通")
            nat1 >> Edge(label="0.0.0.0/0 → sample-igw", color=GREEN) >> igw
            nat2 >> Edge(label="0.0.0.0/0 → sample-igw", color=GREEN) >> igw
        internet = Users("インターネット\n外部サービス\n公開エンドポイント")
        igw >> Edge(label="外向き通信", color=GREEN) >> internet


def services():
    with figure("03  DNS・証明書・S3・メール / 論理連携図", "03-services", "LR"):
        with group("AWS / サブネット配置を表さない論理図", "#FFFFFF"):
            with group("Route 53 / ACM", "#F3F0FA"):
                public = Route53("Public Hosted Zone\nnobu-iac-lab.com\nwww: A Alias / bastion: A / メール: MX")
                private = Route53("Private Hosted Zone: home\nsample-vpcに関連付け\nbastion / web01 / web02: A\ndb: CNAME → RDS endpoint")
                cert = ACM("www.nobu-iac-lab.com\nDNS検証済み証明書\nALBのHTTPS Listenerで利用")
            with group("VPC内リソースの参照", "#EDF5FD"):
                alb = ElbApplicationLoadBalancer("sample-elb\nHTTP 80 / HTTPS 443")
                bastion = EC2("sample-ec2-bastion\nPublic / Private IP")
                web = EC2("sample-ec2-web01 / web02\nS3アップロード元")
                db = RDSMysqlInstance("sample-db\nRDS endpoint")
            with group("S3 / IAM", "#ECF8EF"):
                role = IAMRole("sample-role-web\nInstance Profileも同名\nAmazonS3FullAccess (学習用)")
                upload = S3("nobu-terraform-iac-lab-upload\nアプリのアップロード先\nPublic Access Block有効 / ACL無効")
            with group("SES / メール", "#FFF4F0"):
                ses = SES("nobu-iac-lab.com\n送信: no-reply@ / 受信: inquiry@\nsample-ruleset / sample-rule-inquiry\nDKIM / SPF / DMARC")
                mailbox = S3("nobu-iac-lab-mailbox\ninbox/ にraw MIMEを保存\nPublic Access Block有効 / ACL無効")
        mailusers = Users("外部メール送受信者\nテスト送信先は検証済みアドレス")
        sender = User("SMTP送信テスト\nses-smtp-no-reply の認証情報\n実行元は設計書に指定なし")

        public >> Edge(label="www / A Alias", style="dashed", color=GRAY) >> alb
        public >> Edge(label="bastion / A", style="dashed", color=GRAY) >> bastion
        public >> Edge(label="MX / inbound-smtp\nap-northeast-1.amazonaws.com", style="dashed", color=GRAY) >> ses
        cert >> Edge(label="証明書の関連付け", style="dashed", color=GRAY) >> alb
        private >> Edge(style="dashed", color=GRAY) >> bastion
        private >> Edge(style="dashed", color=GRAY) >> web
        private >> Edge(style="dashed", color=GRAY) >> db
        role >> Edge(label="EC2へ関連付け", style="dashed", color=GRAY) >> web
        web >> Edge(label="S3 API / アップロード", color=GREEN) >> upload
        sender >> Edge(label="SMTP認証 / メール送信", color=PURPLE) >> ses
        ses >> Edge(label="送信メール", color=PURPLE) >> mailusers
        mailusers >> Edge(label="受信メール", color=PURPLE, constraint="false") >> ses
        ses >> Edge(label="受信ルール / スキャン有効", color=PURPLE) >> mailbox


def embed_svg_icons():
    # Graphviz references local icon files; embed them for portable SVG output.
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
    href = "{http://www.w3.org/1999/xlink}href"
    for path in OUT.glob("0*.svg"):
        tree = ET.parse(path)
        for node in tree.iter("{http://www.w3.org/2000/svg}image"):
            source = Path(node.attrib[href])
            encoded = base64.b64encode(source.read_bytes()).decode("ascii")
            node.set(href, f"data:image/png;base64,{encoded}")
        tree.write(path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    network()
    routes()
    services()
    embed_svg_icons()
    print(f"Generated PNG and SVG diagrams in {OUT}")
