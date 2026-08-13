#!/usr/bin/env python3
"""Proxy uzerinden gercek bir SIP cagrisi kurar ve duzgunce kapatir.

Neden bu arac var: verify-08-echo.sh sadece konfigurasyonu ve dialplan
yapisini dogruluyordu, hicbir cagri kurmuyordu. Bu yuzden Kamailio'nun
Proxy-Authorization basligini tuketmemesinden kaynaklanan 407 hatasi butun
otomatik testlerden kacti ve ancak Zoiper ile elle denendiginde goruldu.

Akis (RFC 3261): INVITE -> 407 -> ACK -> INVITE+digest -> 100 -> 200 OK
-> ACK -> (hold) -> BYE -> 200 OK

Cikis kodu 0 sadece 200 OK alinip cagri BYE ile kapatilabildiginde.

Kullanim:
  sip-call-probe.py --proxy IP:PORT --domain D --user U --pass P --dest 9999
"""
import argparse
import hashlib
import random
import re
import socket
import string
import sys
import time


def md5(x: str) -> str:
    return hashlib.md5(x.encode()).hexdigest()


def rnd(n: int = 10) -> str:
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=n))


def digest_response(user, password, realm, nonce, method, uri, chal):
    """RFC 2617 digest. qop="auth" varsa cnonce/nc ile hesaplar."""
    ha1 = md5(f"{user}:{realm}:{password}")
    ha2 = md5(f"{method}:{uri}")
    qop_m = re.search(r'qop="?([^",]+)"?', chal)
    parts = [
        f'username="{user}"', f'realm="{realm}"', f'nonce="{nonce}"',
        f'uri="{uri}"',
    ]
    if qop_m and "auth" in qop_m.group(1):
        cnonce, nc = rnd(16), "00000001"
        resp = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        parts += [f'response="{resp}"', "qop=auth", f"nc={nc}",
                  f'cnonce="{cnonce}"']
    else:
        resp = md5(f"{ha1}:{nonce}:{ha2}")
        parts.append(f'response="{resp}"')
    opaque = re.search(r'opaque="([^"]*)"', chal)
    if opaque:
        parts.append(f'opaque="{opaque.group(1)}"')
    parts.append("algorithm=MD5")
    return "Digest " + ", ".join(parts)


def parse_sdp_media(msg):
    """SDP govdesinden (c= adresi, m=audio portu) dondurur."""
    body = msg.split("\r\n\r\n", 1)
    if len(body) < 2:
        return None, None
    sdp = body[1]
    c = re.search(r"^c=IN IP4 (\S+)", sdp, re.M)
    m = re.search(r"^m=audio (\d+)", sdp, re.M)
    if not c or not m:
        return None, None
    return c.group(1), int(m.group(1))


def rtp_echo_test(ip, port, local_port, count, settle):
    """PCMU RTP gonderir, geri yansiyan paketleri sayar.

    `echo` uygulamasi aldigini geri gonderir; geri gelen paket sayisi > 0 ise
    medya yolu GERCEKTEN iki yonlu calisiyor demektir — SIP sinyalizasyonunun
    kanitlayamadigi tek sey budur.

    Iki tasarim detayi testi kirilgan olmaktan kurtariyor:
      1. `settle` beklemesi: dialplan 9999'da answer'dan sonra sleep(500) var,
         yani echo ilk yarim saniye HENUZ CALISMIYOR. Beklemeden gonderilirse
         paketlerin cogu bosluga gider ve sonuc 25'te 2 gibi marjinal cikar.
      2. Gonderim ve okuma IC ICE: her paketten sonra non-blocking okuma
         yapiliyor. Once-gonder-sonra-dinle deseninde, gonderim bittiginde
         echo'nun yansitacagi paket kalmadigi icin donus suni olarak dusuk
         olur.
    """
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        rx.bind(("0.0.0.0", local_port))
    except OSError:
        rx.bind(("0.0.0.0", 0))
    rx.setblocking(False)

    time.sleep(settle)

    ssrc = random.getrandbits(32)
    payload = b"\xff" * 160          # PCMU sessizlik
    sent = got = 0

    def drain():
        nonlocal got
        while True:
            try:
                data, _ = rx.recvfrom(2048)
            except (BlockingIOError, socket.timeout):
                return
            except OSError:
                return
            # Kendi paketlerimizi saymamak icin farkli SSRC ariyoruz.
            if len(data) >= 12 and data[0] & 0xC0 == 0x80:
                if int.from_bytes(data[8:12], "big") != ssrc:
                    got += 1

    for seq in range(count):
        hdr = (b"\x80\x00"
               + (seq & 0xFFFF).to_bytes(2, "big")
               + ((seq * 160) & 0xFFFFFFFF).to_bytes(4, "big")
               + ssrc.to_bytes(4, "big"))
        try:
            rx.sendto(hdr + payload, (ip, port))
            sent += 1
        except OSError:
            break
        time.sleep(0.02)             # 20 ms ptime
        drain()

    # Kuyrukta kalan yansimalar icin kisa bir tahliye penceresi.
    end = time.time() + 0.6
    while time.time() < end:
        drain()
        time.sleep(0.02)
    rx.close()
    return sent, got


class Probe:
    def __init__(self, a):
        self.a = a
        host, _, port = a.proxy.partition(":")
        self.dst = (host, int(port or 5060))
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.settimeout(1.0)
        self.s.connect(self.dst)
        self.lip, self.lport = self.s.getsockname()
        self.cid = rnd(16)
        self.tag = rnd(8)
        self.totag = None
        self.branch_n = 0
        self.ruri = f"sip:{a.dest}@{a.domain}"

    def log(self, *m):
        print(*m, flush=True)

    def branch(self):
        self.branch_n += 1
        return f"z9hG4bK{rnd(12)}{self.branch_n}"

    def invite(self, cseq, auth=None, branch=None):
        sdp = (
            f"v=0\r\no=- 1 1 IN IP4 {self.lip}\r\ns=-\r\nc=IN IP4 {self.lip}\r\n"
            f"t=0 0\r\nm=audio {self.a.rtp_port} RTP/AVP 0 8 101\r\n"
            "a=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n"
            "a=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n"
        )
        m = (
            f"INVITE {self.ruri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.lip}:{self.lport};branch={branch};rport\r\n"
            f"Max-Forwards: 70\r\n"
            f"From: <sip:{self.a.user}@{self.a.domain}>;tag={self.tag}\r\n"
            f"To: <{self.ruri}>\r\n"
            f"Call-ID: {self.cid}\r\n"
            f"CSeq: {cseq} INVITE\r\n"
            f"Contact: <sip:{self.a.user}@{self.lip}:{self.lport}>\r\n"
        )
        if auth:
            m += f"Proxy-Authorization: {auth}\r\n"
        m += (
            "User-Agent: sip-call-probe\r\nAllow: INVITE, ACK, BYE, CANCEL\r\n"
            f"Content-Type: application/sdp\r\nContent-Length: {len(sdp)}\r\n\r\n{sdp}"
        )
        return m

    def dialog_targets(self, txt):
        """2xx yanitindan dialog hedefini cikarir: (Request-URI, Route seti).

        RFC 3261 12.1.2/12.2.1.1: dialog ici bir istegin Request-URI'si uzak
        tarafin CONTACT'i olmali, Route seti ise Record-Route basliklarinin
        TERS sirasi. Bu yapilmazsa Kamailio'da `loose_route()` basarisiz olur;
        cfg'deki dala gore ACK SESSIZCE ATILIR ve BYE "404 Not Here" alir.
        Belirti cok sinsiydi: FreeSWITCH ACK gelmedigi icin 200 OK'i
        retransmit ediyor, probe de BYE'dan sonra o retransmit'i yakalayip
        "BYE'a 200 OK geldi" saniyordu. Cagri gercekte hic kapanmiyor, 32 sn
        sonra zaman asimiyla dusuyordu (CDR'da duration=32,
        hangup_cause=NORMAL_UNSPECIFIED olarak yakalandi).
        """
        c = re.search(r"^Contact:\s*<([^>]+)>", txt, re.I | re.M)
        ruri = c.group(1) if c else self.ruri
        rr = [v.strip() for v in
              re.findall(r"^Record-Route:\s*(.+)$", txt, re.I | re.M)]
        return ruri, list(reversed(rr))

    def ack(self, cseq, branch, to_hdr, ruri=None, routes=None):
        # 2xx'e ACK yeni bir transaction'dir (yeni branch); 407'ye ACK ise
        # ayni branch'i kullanmak ZORUNDADIR, yoksa proxy 407'yi retransmit eder.
        m = (
            f"ACK {ruri or self.ruri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.lip}:{self.lport};branch={branch};rport\r\n"
            f"Max-Forwards: 70\r\n"
            f"From: <sip:{self.a.user}@{self.a.domain}>;tag={self.tag}\r\n"
            f"To: {to_hdr}\r\n"
            f"Call-ID: {self.cid}\r\n"
            f"CSeq: {cseq} ACK\r\n"
        )
        for r in (routes or []):
            m += f"Route: {r}\r\n"
        return m + "Content-Length: 0\r\n\r\n"

    def bye(self, cseq, to_hdr, ruri=None, routes=None):
        m = (
            f"BYE {ruri or self.ruri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.lip}:{self.lport};branch={self.branch()};rport\r\n"
            f"Max-Forwards: 70\r\n"
            f"From: <sip:{self.a.user}@{self.a.domain}>;tag={self.tag}\r\n"
            f"To: {to_hdr}\r\n"
            f"Call-ID: {self.cid}\r\n"
            f"CSeq: {cseq} BYE\r\n"
        )
        for r in (routes or []):
            m += f"Route: {r}\r\n"
        return m + "Content-Length: 0\r\n\r\n"

    def recv_until(self, want, timeout):
        """Bu Call-ID'ye ait, kodu `want` regex'iyle eslesen ilk yaniti dondurur."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            txt = data.decode(errors="replace")
            if f"Call-ID: {self.cid}" not in txt:
                continue
            line = txt.split("\r\n")[0]
            if not line.startswith("SIP/2.0"):
                continue
            code = line.split()[1]
            self.log(f"    <- {line}")
            # TUM 1xx provisional yanitlar atlanir, sadece 100 degil.
            # Kullanicidan kullaniciya cagrida cagrilan taraf 180 Ringing
            # gonderir; yalnizca 100 atlanirsa 180 final yanit sanilip
            # "200 OK bekleniyordu, 180 geldi" ile hatali FAIL uretilir.
            if code.startswith("1"):
                continue
            if re.match(want, code):
                return code, txt
            return code, txt
        return None, None

    def run(self):
        a = self.a
        self.log(f"--- Cagri: {a.user}@{a.domain} -> {a.dest} "
                 f"(proxy {self.dst[0]}:{self.dst[1]}, Call-ID {self.cid}) ---")

        # 1) Kimlik dogrulamasiz INVITE -> 407 bekleniyor
        b1 = self.branch()
        self.log("  1) INVITE (kimlik dogrulamasiz)")
        self.s.send(self.invite(1, branch=b1).encode())
        code, txt = self.recv_until(r"40[17]", 5)
        if code is None:
            self.log("FAIL: proxy INVITE'a hic yanit vermedi")
            return 1
        if code not in ("401", "407"):
            self.log(f"FAIL: 407 bekleniyordu, {code} geldi (acik relay?)")
            return 1

        m = re.search(r"(?:Proxy|WWW)-Authenticate:\s*Digest\s*(.*)", txt, re.I)
        if not m:
            self.log("FAIL: 407 yanitinda Digest challenge yok")
            return 1
        chal = m.group(1)
        realm = re.search(r'realm="([^"]+)"', chal).group(1)
        nonce = re.search(r'nonce="([^"]+)"', chal).group(1)
        to_hdr = re.search(r"^To:\s*(.+)$", txt, re.I | re.M).group(1).strip()

        # 407 ACK'lenmezse proxy yaniti retransmit eder ve iz kirlenir.
        self.log("  2) ACK (407 icin, ayni branch)")
        self.s.send(self.ack(1, b1, to_hdr).encode())

        # 2) Digest ile INVITE -> 200 OK bekleniyor
        auth = digest_response(a.user, a.password, realm, nonce, "INVITE",
                               self.ruri, chal)
        self.log("  3) INVITE (digest ile)")
        self.s.send(self.invite(2, auth=auth, branch=self.branch()).encode())
        code, txt = self.recv_until(r"2\d\d", 15)
        if code is None:
            self.log("FAIL: kimlik dogrulamali INVITE'a son yanit gelmedi "
                     "(cagri kurulmadi)")
            return 1
        if not code.startswith("2"):
            hint = ""
            if code in ("401", "407"):
                # Ikinci 407'nin IKI ayri sebebi olabilir; karistirilirsa
                # yanlis teshise goturur, o yuzden yanitin KAYNAGINA bakiyoruz.
                # FreeSWITCH'in urettigi challenge "stale=true" tasir ve
                # User-Agent'i mod_sofia'dir; Kamailio'nunki ikisini de tasimaz.
                from_fs = ("stale=true" in txt) or ("FreeSWITCH" in txt)
                if from_fs:
                    hint = ("  >>> Challenge FreeSWITCH'ten geliyor (stale=true / "
                            "mod_sofia): Kamailio digest'i dogruladi ama "
                            "Proxy-Authorization basligini TUKETMEDI, FreeSWITCH "
                            "o basligi gorup kendi dogrulamasini calistiriyor. "
                            "kamailio.cfg'de consume_credentials() eksik veya "
                            "calisan image bayat (up -d --build gerekir).")
                else:
                    hint = ("  >>> Challenge proxy'den (Kamailio) geliyor: kimlik "
                            "bilgileri reddedildi — kullanici/sifre/realm yanlis "
                            "ya da subscriber.ha1 bu realm icin hesaplanmamis.")
            elif code == "503":
                hint = "  >>> dispatcher hedefi yok/inaktif."
            self.log(f"FAIL: 200 OK bekleniyordu, {code} geldi")
            if hint:
                self.log(hint)
            return 1

        to_hdr = re.search(r"^To:\s*(.+)$", txt, re.I | re.M).group(1).strip()
        if a.abandon:
            # TESHIS MODU: 200 OK'e ACK GONDERMEDEN cikiyoruz. Bu, FreeSWITCH
            # tarafinda cagrinin zaman asimiyla anormal sonlandirilmasini
            # tetikler ve SIGSEGV suphesini deterministik olarak sinar.
            # Uretimde ASLA kullanilmaz; sadece scripts/repro-segv.sh icin.
            self.log("  4) ACK GONDERILMIYOR (--abandon) — cagri terk edildi")
            return 0
        d_ruri, d_routes = self.dialog_targets(txt)
        self.log(f"  4) ACK (200 OK icin) -> {d_ruri}"
                 + (f" via {len(d_routes)} Route" if d_routes else ""))
        _ackmsg = self.ack(2, self.branch(), to_hdr, d_ruri, d_routes)
        if a.verbose:
            self.log("  --- GONDERILEN ACK ---\n" + _ackmsg)
        self.s.send(_ackmsg.encode())

        # --- Medya: SDP'de duyurulan adres/port ---
        media_ip, media_port = parse_sdp_media(txt)
        if media_ip is None:
            self.log("FAIL: 200 OK icinde ayristirilabilir bir SDP yok")
            return 1
        self.log(f"  5) uzak medya adresi: {media_ip}:{media_port}")

        # Bu kontrol AGDAN BAGIMSIZ ve deterministik: FreeSWITCH konteyner-ici
        # adresini (172.x) duyurursa hicbir dis istemci oraya RTP gonderemez ve
        # "cagri kuruluyor ama ses yok" olur. Sebebi genelde local-network-acl:
        # varsayilan `localnet.auto` RFC1918'i "yerel" saydigi icin, sinyalin
        # geldigi Kamailio (172.x) yerel gorunur ve ext-rtp-ip DEVREYE GIRMEZ.
        if a.expect_media_ip and media_ip != a.expect_media_ip:
            self.log(f"FAIL: SDP'de {a.expect_media_ip} bekleniyordu, "
                     f"{media_ip} duyuruldu")
            if media_ip.startswith(("172.", "10.", "192.168.")) \
                    and media_ip != a.expect_media_ip:
                self.log("  >>> Duyurulan adres bir ic/konteyner adresi. "
                         "FreeSWITCH ext-rtp-ip'yi kullanmiyor — sip_profiles/"
                         "internal.xml icinde local-network-acl=none gerekiyor "
                         "(varsayilan localnet.auto, Kamailio'yu yerel sayar).")
            return 1

        # --- Gercek RTP: echo donuyor mu ---
        self.log(f"  6) RTP echo olcumu ({a.rtp_packets} paket PCMU)")
        sent, got = rtp_echo_test(media_ip, media_port, self.a.rtp_port,
                                  a.rtp_packets, a.rtp_settle)
        pct = (100 * got // sent) if sent else 0
        self.log(f"     gonderildi={sent} alindi={got} ({pct}%)")
        # Esik neden 0 degil: bir-iki paket, yolun gercekten calistigini degil
        # tesadufi bir yansimayi da gosterebilir. Echo saglikli calistiginda
        # donus orani yuksektir; %25 kayip toleransi birakip altini basarisiz
        # sayiyoruz ki "ses var ama kirik" durumu yesil gorunmesin.
        if got < max(1, sent // 4):
            self.log(f"FAIL: RTP echo yetersiz ({got}/{sent}) — cagri kuruldu "
                     "ama ses akmiyor veya ciddi kayip var")
            self.log("  >>> Kontrol: SDP adresi/portu erisilebilir mi, RTP port "
                     "araligi compose'da publish edilmis mi (16384-16403), echo "
                     "uygulamasi calisti mi (fs_cli loglari).")
            return 1

        self.log(f"  7) cagri {a.hold}s ayakta tutuluyor")
        time.sleep(a.hold)

        # 3) BYE ile kapat. Bu adim ayni zamanda "cagri sonlandirmada
        #    FreeSWITCH cokuyor mu" suphesini de sinar.
        self.log("  6) BYE")
        self.s.send(self.bye(3, to_hdr, d_ruri, d_routes).encode())
        code, _ = self.recv_until(r"2\d\d", 5)
        if code is None or not code.startswith("2"):
            self.log(f"FAIL: BYE'a 200 OK gelmedi (gelen: {code})")
            return 1

        self.log("OK: cagri kuruldu (200 OK) ve BYE ile temiz kapatildi")
        return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--proxy", required=True, help="IP veya IP:PORT")
    p.add_argument("--domain", required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--hold", type=float, default=2.0)
    p.add_argument("--rtp-port", type=int, default=40200)
    p.add_argument("--expect-media-ip", default=None,
                   help="SDP'de duyurulmasi beklenen medya adresi "
                        "(genelde EXTERNAL_IP)")
    p.add_argument("--rtp-packets", type=int, default=50)
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--abandon", action="store_true",
                   help="TESHIS: 200 OK'e ACK gondermeden cik (SIGSEGV repro)")
    p.add_argument("--rtp-settle", type=float, default=0.8,
                   help="RTP gondermeden once beklenecek sure; dialplan\n"
                        "9999 answer sonrasi sleep(500) yapiyor")
    sys.exit(Probe(p.parse_args()).run())


if __name__ == "__main__":
    main()
