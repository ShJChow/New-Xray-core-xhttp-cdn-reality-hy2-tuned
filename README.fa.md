# xray-xhttp

**زبان‌ها:** [简体中文](./README.md) · [English](./README.en.md) · **فارسی**

> **نود `xhttp+udp+cdn` در نرم‌افزار onexray (iOS) بسیار سریع است — در آزمایش‌های ما سریع‌تر از Hysteria2** (اندازه‌گیری روی Oracle با ۴ OCPU و ۲۴ گیگابایت رم).

راه‌اندازی یک‌مرحله‌ای **XHTTP با تفکیک مسیر ارسال و دریافت از طریق CDN**، بر پایهٔ Xray-core و روی پورت ۴۴۳. قابلیت **xpadding به‌صورت پیش‌فرض فعال** است (ECH اختیاری)، و دستور مدیریتی `xh` نیز همراه آن نصب می‌شود.

با V2rayN / Shadowrocket / Mihomo / onexray کار می‌کند و از IPv4 و IPv6 پشتیبانی می‌شود.

> **مطالعهٔ مبانی**: XHTTP، تفکیک مسیر ارسال و دریافت، و دلیل مقاومت آن در برابر سانسور — <https://habr.com/en/articles/990208/>
>
> **توجه**: این پیکربندی از VLESS Encryption استفاده می‌کند. کلاینت شما (V2rayN یا Mihomo) باید به نسخه‌ای به‌روز باشد که از `vlessenc` و `xhttp` پشتیبانی کند.
>
> **توجه**: نسخهٔ V2rayN v7.19.5 و بالاتر ممکن است در حالت TUN ناپایدار باشد؛ گزینهٔ محافظت TUN قدیمی را فعال کنید ([PR #9005](https://github.com/2dust/v2rayN/pull/9005)).

پس از نصب نودها و افزونهٔ Hysteria2، دستور **`xh tuning on`** را اجرا کنید.

---

## ویژگی‌ها

| قابلیت | توضیح |
|---|---|
| مجموعهٔ نودها (v2.0.2) | دو نود Reality مستقیم + `xhttp-tls-UDP-cdn` (سریع‌ترین در آزمایش) + افزونهٔ Hysteria2. دو نود تفکیک‌شده را می‌توان با `FEATURE_SPLIT_NODES=true` بازگرداند |
| xpadding | پیش‌فرض فعال — `xPaddingObfsMode` به‌همراه هدر و نام پارامتر سفارشی، برای عبور از تشخیص الگوی XHTTP در سمت CDN |
| ECH | اختیاری؛ مقدار SNI را داخل دست‌دادن TLS رمزگذاری می‌کند |
| VLESS Encryption | پیش‌فرض فعال (ML-KEM-768)، تا CDN نتواند به‌عنوان واسط ترافیک را رمزگشایی کند |
| **تنظیمات سیستمی** | BBR + fq، TFO، کاوش MTU، سقف توصیف‌گر فایل ۱۰۴۸۵۷۶، `sockopt` در Xray، و افزایش زمان انتظار اتصال‌های بلندمدت gRPC در Nginx |
| **تطبیق با سخت‌افزار** | سه رده بر اساس مقدار رم (≥۱۶ گیگ / ≥۴ گیگ / <۴ گیگ) بافرها و صف‌ها را مقیاس می‌دهد؛ اندازهٔ صفحهٔ حافظه در زمان اجرا خوانده می‌شود و ثابت فرض نمی‌شود |
| flow / Vision | نود ۱ از `xtls-rprx-vision` استفاده می‌کند (تنها نودی که می‌تواند از Splice بهره ببرد). بقیه XHTTP هستند و بر اساس پروتکل نمی‌توانند flow داشته باشند. با `VISION_UDP443=1` به `-udp443` تغییر می‌کند |
| **دستور `xh`** | وضعیت / اطلاعات نود / لینک اشتراک / لاگ / به‌روزرسانی هسته / کلید تنظیمات / زنده‌نگه‌داری / حذف کامل |
| **نصب غیرتعاملی** | کاملاً با متغیرهای محیطی؛ با `AUTO=1` بدون هیچ پرسشی نصب می‌شود |
| **خودترمیمی** | بررسی سلامت با cron هر ۵ دقیقه، به‌همراه اجرای خودکار در بوت |
| **به‌روزرسانی خودکار هسته** | Xray-core هفتگی به‌روز می‌شود و اگر بررسی پیکربندی شکست بخورد، خودکار به نسخهٔ قبل بازمی‌گردد |
| افزونه‌ها | CDN متفاوت برای هر جهت · ارسال روی IPv4 و دریافت روی IPv6 · Hysteria2 |

---

## فهرست نودها

از نسخهٔ v2.0.2 به‌صورت پیش‌فرض **۳ نودِ جدول زیر** تولید می‌شود — با افزودن افزونهٔ Hysteria2 در مجموع ۴ نود.

نود ۳ یعنی `Vless-xhttp-tls-UDP-cdn` **سریع‌ترین آن‌ها در آزمایش** است (به یادداشت بالای صفحه نگاه کنید).

نود ۳ از CDN می‌گذرد و آدرس سرورش یک دامنه است، پس **در حالت TUN نرم‌افزار V2rayN باید دامنهٔ CDN را به فهرست اتصال مستقیم (bypass) اضافه کنید**، وگرنه ترافیک روی خودش حلقه می‌زند. اسکریپت نصب فایل `~/client-config-v2rayn-tun.txt` را می‌سازد که این فهرست را با مقادیر واقعی همان سرور آماده کرده است.

نام نودها فقط از حروف ASCII به‌همراه پسوند نام میزبان تشکیل شده است (`<host>` همان `hostname -s` است):

| # | نام نود | مسیر | ترابرد |
|---|---|---|---|
| ۱ | `Vless-reality-vision-<host>` | مستقیم به VPS، TCP 443 | Reality + Vision؛ گزینهٔ پشتیبان وقتی UDP مسدود است |
| ۲ | `Vless-xhttp-reality-<host>` | مستقیم به VPS، TCP 443 | XHTTP + Reality، ارسال و دریافت روی یک مسیر |
| ۳ | `Vless-xhttp-tls-UDP-cdn-<host>` | از طریق CDN، **UDP 443** | XHTTP + TLS، alpn h3 — **سریع‌ترین در آزمایش** |

دو نود دیگر با **تفکیک مسیر ارسال و دریافت** (`Vless-xhttp-split-cdnup-realitydown` و `Vless-xhttp-split-realityup-cdndown`) پیش‌فرض خاموش‌اند: پیچیده‌ترین پیکربندی را دارند و سودشان هرگز اندازه‌گیری نشده است. تمام زیرساخت سمت سرور دست‌نخورده باقی می‌ماند، بنابراین `FEATURE_SPLIT_NODES=true` آن‌ها را بدون تغییر در کد بازمی‌گرداند.

---

## پیش‌نیازها

قبل از اجرای اسکریپت، این موارد را در Cloudflare تنظیم کنید:

۱. DNS دامنهٔ Reality → **DNS only** (ابر خاکستری)
۲. DNS دامنهٔ CDN → **Proxied** (ابر نارنجی)
۳. رمزگذاری SSL/TLS → **Full (strict)**
۴. بخش Network → **گزینهٔ gRPC فعال باشد**
۵. قواعد کش (توصیه می‌شود) → مسیر XHTTP را روی bypass cache بگذارید؛ عبارت دقیق را اسکریپت پس از پایان نصب چاپ می‌کند
۶. برای ECH → ابتدا ECH را در بخش Edge Certificates فعال کنید

هر دامنهٔ ورودی از فایل `dist/<دامنه>/index.html` خودش به‌عنوان صفحهٔ پوششی استفاده می‌کند. می‌توانید یک صفحهٔ واقعی را با [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) ذخیره کنید و آپلود نمایید.

---

## نصب یک‌مرحله‌ای (توصیه‌شده: XHTTP همراه با xpadding)

> **حداقل نسخه‌ها**: هستهٔ Xray نسخهٔ `26.2.6` یا بالاتر، هستهٔ Mihomo نسخهٔ `1.19.24` یا بالاتر.
> xpadding پیش‌فرض فعال است؛ ECH اختیاری و پیش‌فرض خاموش است.

روی Debian یا Ubuntu:

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

### نسخهٔ ساده، بدون xpadding

> هستهٔ Mihomo نسخهٔ `1.19.23` کافی است.

```bash
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

اجرای مجدد اسکریپت بی‌خطر است — برای تغییر دامنه‌ها، سایت پوششی و سایر پارامترها از همین روش استفاده کنید.

**اجرای مجدد همهٔ UUID‌ها و کلیدها را از نو می‌سازد**، بنابراین پیکربندی‌های قبلی کلاینت از کار می‌افتند. اگر این موضوع اهمیت دارد، ابتدا نسخهٔ پشتیبان بگیرید:

```bash
cp -a /etc/xhttp-cdn/node.env ~/node.env.bak.$(date +%F)
cp -a ~/client-config.txt ~/client-config.txt.bak.$(date +%F)
```

---

## افزونه‌ها

این‌ها را پس از اسکریپت اصلی اجرا کنید. مقادیر موجود `UUID / Path / VLESS Encryption` را دوباره استفاده می‌کنند و پیکربندی کلاینت و لینک اشتراک را به‌روز می‌کنند.

```bash
# Hysteria2، اتصال مستقیم
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

> از نسخهٔ v2.0.1 این افزونه به‌صورت پیش‌فرض **فقط `Hysteria2-direct` را تولید می‌کند**. نود `Vless-xhttp-tls-h3-direct` به `FEATURE_XHTTP_H3_NODE=true` نیاز دارد.
> آن نود **در عمل زیر Shadowrocket کار نمی‌کند** (به همان دلیلی که اسکریپت اصلی نود h3 مستقیم را پیش‌تر غیرفعال کرده بود) — اصلاحیه را در [docs/8](./docs/8.拓展-QUIC添加.md) ببینید. اگر فقط Hysteria2 را می‌خواهید، افزونه را طبق معمول اجرا کنید و نود h3 را نادیده بگیرید.

### نصب غیرتعاملی (نصب مجدد اسکریپتی)

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu \
CDN_FALLBACK_ORIGIN=https://www.harvard.edu \
CDN_ECH=n \
bash ~/install-xpadding.sh
```

متغیرهای محیطی موجود:

| متغیر | معنا | پیش‌فرض |
|---|---|---|
| `AUTO` | مقدار `1` یعنی بدون هیچ پرسشی | `0` |
| `REALITY_DOMAIN` / `CDN_DOMAIN` | دو دامنه — **الزامی** | — |
| `IP_CHOICE` | `1` برای IPv4 و `2` برای IPv6 | `1` |
| `FALLBACK_MODE` | `static` (صفحهٔ محلی) یا `proxy` (پروکسی معکوس) | `proxy` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | سایت پوششی در حالت `proxy` | sjsu / harvard |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | فیلدهای xpadding | `Referer` / `x_padding` |
| `CDN_ECH` | مقدار `y` قابلیت ECH را فعال می‌کند | `n` |
| `VISION_UDP443` | مقدار `1` باعث می‌شود نود ۱ از `xtls-rprx-vision-udp443` استفاده کند (نیازمند پشتیبانی کلاینت) | `0` |
| `FEATURE_SPLIT_NODES` | مقدار `true` دو نود تفکیک‌شده را بازمی‌گرداند | `false` |
| `FEATURE_XHTTP_H3_NODE` | کلید افزونهٔ Hysteria2: مقدار `true` نود `Vless-xhttp-tls-h3-direct` و شنوندهٔ quic در nginx را بازمی‌گرداند | `false` |
| `FEATURE_KEEPALIVE` | مقدار `false` از نصب cron زنده‌نگه‌داری صرف‌نظر می‌کند | `true` |
| `FEATURE_AUTOUPDATE` | مقدار `false` از نصب cron به‌روزرسانی خودکار صرف‌نظر می‌کند | `true` |

با `AUTO=1` و `FALLBACK_MODE=static` یک فایل `index.html` جایگزین ساخته می‌شود و تأیید دستی رد می‌شود؛ بعداً می‌توانید آن را عوض کنید.

---

## دستور `xh`

به‌محض پایان نصب در دسترس است. جزئیات در [docs/11](./docs/11.管理命令.md) آمده است.

```text
xh                      منوی تعاملی
xh status               وضعیت سرویس‌ها / پورت‌های شنونده / وضعیت تنظیمات / نسخه‌ها
xh info                 پارامترهای نود و لینک نودهای کلاینت
xh sub                  لینک اشتراک و کد QR
xh log [xray|nginx]     دنبال کردن لاگ
xh start|stop|restart   کنترل سرویس
xh update [--auto]      به‌روزرسانی Xray-core (در صورت شکست بررسی، بازگشت خودکار)
xh tuning [show|on|off] نمایش / اعمال / بازگرداندن تنظیمات سطح سیستم
xh diag                 خودآزمایی سمت سرور وقتی نودی وصل نمی‌شود
xh conflict             یافتن فایل‌هایی در /etc/sysctl.d/ که مقادیر این پروژه را بازنویسی می‌کنند
xh keepalive [on|off]   کلید زنده‌نگه‌داری
xh autoupdate [on|off]  کلید به‌روزرسانی خودکار هسته
xh version              نسخهٔ پروژه و Xray-core
xh uninstall            حذف کامل همهٔ اجزا
```

---

## تنظیمات سطح سیستم

### دستور `xh tuning on` چه کاری انجام می‌دهد

فعال‌کردن BBR + fq، تنظیم `rmem/wmem` (۶۴/۳۲/۱۶ مگابایت بر اساس ردهٔ رم)، `tcp_fastopen=3`، `tcp_mtu_probing=1`، `tcp_slow_start_after_idle=0`، `tcp_notsent_lowat`، `somaxconn=65535`، بافرهای UDP (برای QUIC و H3)، و همچنین `limits.d` و یک drop-in برای systemd با `nofile=1048576`.

همهٔ این مقادیر در فایل‌های مستقل نوشته می‌شوند: `/etc/sysctl.d/99-xray-xhttp.conf` و `/etc/security/limits.d/99-xray-xhttp.conf`. **فایل `sysctl.conf` فعلی شما هرگز تغییر نمی‌کند** و به یونیت رسمی Xray هم دست زده نمی‌شود (از drop-in استفاده می‌شود، پس به‌روزرسانی هسته آن را بازنویسی نخواهد کرد).

تمام تنظیمات **best-effort** هستند: در محیط‌هایی مثل OpenVZ یا LXC که sysctl فقط خواندنی است، هر مورد به‌تنهایی با یک هشدار رد می‌شود و اجرا متوقف نمی‌گردد. دستور `xh tuning off` همه چیز را برمی‌گرداند. جدول کامل پارامترها در [docs/10](./docs/10.流控调优.md) است.

> **تأیید نشده**: این‌که این مقادیر واقعاً توان عبوری را روی دستگاه *شما* بهتر می‌کنند یا نه. هیچ اندازه‌گیری کنترل‌شده‌ای برای این پروژه انجام نشده است. دقیقاً به همین دلیل تنظیمات پیش‌فرض خاموش‌اند — اول نودها را راه بیندازید، بعد اگر خواستید فعال کنید و مقایسه نمایید.

یک اسکریپت مستقل هم به نام `tools/vps-tune.sh` وجود دارد، برای وقتی که ترجیح می‌دهید از `xh` استفاده نکنید. این اسکریپت از `--dry-run` و `--rollback` پشتیبانی می‌کند و اگر `xh tuning` فعال باشد اجرا نمی‌شود، تا هیچ‌کدام مسیر بازگشت دیگری را بی‌صدا از بین نبرد.

---

## نصب دستی

اگر نمی‌خواهید اسکریپت را اجرا کنید، پوشهٔ `docs/` را به‌ترتیب بخوانید (متن چینی است):

۱. [1.环境配置.md](./docs/1.环境配置.md) — آماده‌سازی محیط
۲. [2.文件配置.md](./docs/2.文件配置.md) — پیکربندی فایل‌ها
۳. [3.xpadding配置.md](./docs/3.xpadding配置.md) — تنظیم xpadding
۴. [4.ECH配置.md](./docs/4.ECH配置.md) — تنظیم ECH
۵. [5.流程图.md](./docs/5.流程图.md) — نمودار جریان
۶. [6.拓展-上下行不同CDN.md](./docs/6.拓展-上下行不同CDN.md) — CDN متفاوت برای هر جهت
۷. [7.拓展-上下行IPv4IPv6.md](./docs/7.拓展-上下行IPv4IPv6.md) — ارسال IPv4 و دریافت IPv6
۸. [8.拓展-QUIC添加.md](./docs/8.拓展-QUIC添加.md) — افزودن QUIC و Hysteria2
۹. [9.卸载.md](./docs/9.卸载.md) — حذف نصب
۱۰. [10.流控调优.md](./docs/10.流控调优.md) — مرجع تنظیمات
۱۱. [11.管理命令.md](./docs/11.管理命令.md) — مرجع دستور `xh`
۱۲. [12.机型调优-OracleARM.md](./docs/12.机型调优-OracleARM.md) — یادداشت‌های Oracle ARM

---

## فایل‌های خروجی

- `~/client-config.txt` — نودها برای V2RayN و Shadowrocket
- `~/client-config-v2rayn-tun.txt` — فهرست اتصال مستقیم برای حالت TUN در V2rayN، آماده‌شده برای همین سرور
- `~/client-config-mihomo-full.yaml` — پیکربندی کامل Mihomo همراه با قواعد مسیریابی
- `~/client-config-mihomo-nodes.yaml` — فقط نودهای Mihomo
- `~/subscription-links.txt` و `~/subscription-*.png` — لینک اشتراک و کد QR
- `/etc/xhttp-cdn/node.env` — پارامترهای نود (با دسترسی 0600، توسط `xh` خوانده می‌شود)

اگر از قبل پیکربندی Mihomo دارید، از `mihomo-nodes.yaml` استفاده کنید.

---

## اگر مشکلی پیش آمد: پاک‌سازی و اجرای مجدد

حذف نصب نیمه‌کاره می‌تواند وضعیتی به‌جا بگذارد که در آن فرایند هنوز در حال اجراست، در حالی که فایل یونیت و فایل اجرایی‌اش پاک شده‌اند. در این حالت نصب‌کنندهٔ رسمی Xray با پیام `Unit xray.service not loaded` شکست می‌خورد. این‌گونه پاک‌سازی کنید:

```bash
pkill -9 -x xray; pkill -9 -f 'xray run'
rm -f  /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
rm -f  /usr/local/bin/xray
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
systemctl daemon-reload && systemctl reset-failed

pgrep -a xray || echo "clean"
bash ~/install.sh
```

با ارسال یک تگ `v*` به مخزن، GitHub Actions به‌صورت خودکار خروجی‌ها را می‌سازد و یک Release منتشر می‌کند.

---

## سپاس‌گزاری و مجوز

این پروژه بر پایهٔ [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config) (مجوز MIT) ساخته شده است.

شکل کلی محصول — دستور مدیریتی، نصب غیرتعاملی، خودترمیمی و به‌روزرسانی خودکار هسته — از [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) (مجوز GPL-3.0) الگو گرفته است؛ آن کد پیاده‌سازی مستقل خودمان است و هیچ بخشی از منبع آن کپی نشده.

جزئیات در [NOTICE.md](./NOTICE.md). مجوز: [MIT](./LICENSE).

## منابع

- راهنمای مقدماتی Xray: <https://xtls.github.io/document/level-0/ch07-xray-server.html>
- XHTTP: Beyond REALITY: <https://github.com/XTLS/Xray-core/discussions/4113>
- بحث تفکیک ارسال و دریافت روی CDN: <https://github.com/XTLS/Xray-core/discussions/4118>
- مستندات Xray SockoptObject: <https://xtls.github.io/config/transports/sockopt.html>
- نسخهٔ Xray-core v26.2.6 (xpadding): <https://github.com/XTLS/Xray-core/releases/tag/v26.2.6>
- بحث نشت xpadding: <https://github.com/XTLS/Xray-core/issues/4346> · <https://github.com/XTLS/BBS/issues/25>
- بحث XHTTP در Mihomo: <https://github.com/MetaCubeX/mihomo/discussions/2669>
- مستندات Mihomo (بخش Transport): <https://wiki.metacubex.one/config/proxies/transport/>
- قابلیت ECH در Cloudflare: <https://developers.cloudflare.com/ssl/edge-certificates/ech/>
