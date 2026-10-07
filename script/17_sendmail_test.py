# -*- coding: utf-8 -*-

# export SES_SMTP_USER='SMTPユーザー名'
# export SES_SMTP_PASSWORD='SMTPパスワード'


import os
import smtplib
from email.mime.text import MIMEText
from email.header import Header

# SES SMTP接続情報
# SMTP_USER / SMTP_PASSWORD は環境変数から読み込む。
# GitHubに認証情報を載せないため、コードには直接書かない。
account = os.environ["SES_SMTP_USER"]
password = os.environ["SES_SMTP_PASSWORD"]

# Amazon SES SMTP endpoint
# 東京リージョン ap-northeast-1 のSMTPエンドポイント。
server = "email-smtp.ap-northeast-1.amazonaws.com"
port = 587

# SESで認証済みの送信元メールアドレス。
# Domain Identity nobu-iac-lab.com を検証済みにしているため、
# no-reply@nobu-iac-lab.com を送信元として利用する。
from_addr = "no-reply@nobu-iac-lab.com"

# SES sandbox中は、送信先も検証済みメールアドレスである必要がある。
to_addr = "nobu4071@icloud.com"

# 送信するメール本文を作成する。
charset = "utf-8"
message = MIMEText("SMTPのテスト", "plain", charset)
message["Subject"] = Header("SMTP経由での電子メールのテスト", charset)
message["From"] = from_addr
message["To"] = to_addr

# SMTPサーバーに接続してメールを送信する。
# 587番ポートではSTARTTLSを使って暗号化する。
with smtplib.SMTP(server, port) as con:
    con.set_debuglevel(1)
    con.starttls()
    con.login(account, password)
    con.sendmail(from_addr, [to_addr], message.as_string())

print("Mail sent successfully.")

