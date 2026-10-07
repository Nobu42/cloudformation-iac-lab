## パケットキャプチャによるDNS確認

Route 53で作成したPublic DNSレコードが、実際に名前解決されていることを `tcpdump` で確認した。

この確認はMac上で実施した。

### 実行コマンド

まず、MacのWi-Fiインターフェースを対象にDNS通信をキャプチャする。

```bash
sudo tcpdump -i en0 -n port 53
```

別ターミナルで、DNS名前解決を実行する。

```bash
dig bastion.nobu-iac-lab.com
dig www.nobu-iac-lab.com
```

### 実行結果

`bastion.nobu-iac-lab.com` の名前解決では、以下のようなDNS問い合わせと応答を確認できた。

```text
192.168.40.101.51034 > 192.168.40.208.53: A? bastion.nobu-iac-lab.com.
192.168.40.208.53 > 192.168.40.101.51034: A 43.206.215.171
```

これは、MacからDNSサーバーへ `bastion.nobu-iac-lab.com` のAレコードを問い合わせ、BastionサーバーのPublic IPである `43.206.215.171` が返ってきたことを示している。

`www.nobu-iac-lab.com` の名前解決では、以下のようにALBのIPアドレスが複数返ってきた。

```text
192.168.40.101.63679 > 192.168.40.208.53: A? www.nobu-iac-lab.com.
192.168.40.208.53 > 192.168.40.101.63679: A 3.115.185.66, A 13.192.190.8
```
> `192.168.40.208:53` は、自宅のラズパイ上に構築しているDNSサーバーを示している。

ALBは複数のIPアドレスを返すため、Aレコードの応答に複数IPが含まれることがある。

### 読み取り方

| 表示 | 意味 |
| :--- | :--- |
| `192.168.40.101` | DNS問い合わせを行ったMac |
| `192.168.40.208.53` | DNSサーバーの53番ポート |
| `A? bastion.nobu-iac-lab.com.` | Bastion用DNS名のIPv4アドレスを問い合わせ |
| `A 43.206.215.171` | BastionのPublic IPが返ってきた |
| `A? www.nobu-iac-lab.com.` | ALB用DNS名のIPv4アドレスを問い合わせ |
| `A 3.115.185.66, A 13.192.190.8` | ALBのIPアドレスが返ってきた |

### 学んだこと

- Route 53で作成したPublic DNSレコードが、実際にDNS問い合わせとして流れていることを確認できた
- `bastion.nobu-iac-lab.com` はBastionサーバーのPublic IPへ名前解決された
- `www.nobu-iac-lab.com` はALBへ名前解決された
- ALBは複数のIPアドレスを返すことがある
- `tcpdump` を使うと、DNS問い合わせと応答をパケットレベルで確認できる

### 注意事項

`tcpdump` は管理者権限が必要なため、Macでは `sudo` を付けて実行する。

Wi-Fiインターフェースが `en0` ではない環境では、以下のコマンドでインターフェース名を確認する。

```bash
networksetup -listallhardwareports
```

ブラウザや他のアプリケーションが裏でDNS問い合わせを行うため、キャプチャ結果には今回の検証とは関係ない名前解決が混ざることがある。

