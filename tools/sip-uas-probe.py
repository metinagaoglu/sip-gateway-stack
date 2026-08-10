#!/usr/bin/env python3
"""Kayit olan ve gelen cagriyi cevaplayan minimal bir SIP UAS (cagrilan taraf).

Neden bu arac var: planin Task 9 adimi "iki Zoiper ile elle" dogrulama
onerdi. Bu oturumda elle dogrulamaya birakilan IKI kusur (Kamailio'nun
Proxy-Authorization'i tuketmemesi ve FreeSWITCH'in SDP'de konteyner adresini
duyurmasi) butun otomatik testlerden kacti. Bu yuzden cagrilan taraf da
otomatiklestirildi: bu script `bob` olarak kayit olur, gelen INVITE'i
cevaplar ve aldigi RTP'yi geri yansitir.

Akis:
  REGISTER -> 401 -> REGISTER+digest -> 200 OK
  (INVITE bekle) -> 100 -> 180 -> 200 OK+SDP -> (ACK bekle)
  RTP yansit -> (BYE bekle) -> 200 OK

Cikti son satirda makine-okunur: RESULT key=value ...
Cikis kodu 0 sadece cagri cevaplanip RTP alindiginda.
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
    ha1 = md5(f"{user}:{realm}:{password}")
    ha2 = md5(f"{method}:{uri}")
    qop_m = re.search(r'qop="?([^",]+)"?', chal)
    parts = [f'username="{user}"', f'realm="{realm}"', f'nonce="{nonce}"',
             f'uri="{uri}"']
    if qop_m and "auth" in qop_m.group(1):
        cnonce, nc = rnd(16), "00000001"
        parts += [f'response="{md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")}"',
                  "qop=auth", f"nc={nc}", f'cnonce="{cnonce}"']
    else:
        parts.append(f'response="{md5(f"{ha1}:{nonce}:{ha2}")}"')
    parts.append("algorithm=MD5")
    return "Digest " + ", ".join(parts)


def hdr(msg, name):
    m = re.search(rf"^{name}:\s*(.+)$", msg, re.I | re.M)
    return m.group(1).strip() if m else ""


class UAS:
    def __init__(self, a):
        self.a = a
        host, _, port = a.proxy.partition(":")
        self.dst = (host, int(port or 5060))
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("0.0.0.0", a.sip_port))
        self.s.settimeout(0.5)
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(self.dst)
        self.lip = probe.getsockname()[0]
        probe.close()
        self.lport = a.sip_port
        self.contact = f"<sip:{a.user}@{self.lip}:{self.lport}>"
        self.peer = None      # INVITE'in geldigi kaynak (yanitlar buraya)

    def log(self, *m):
        print(*m, flush=True)

    def send(self, msg):
        self.s.sendto(msg.encode(), self.dst)

    # ---------- Kayit ----------
    def register(self):
        a = self.a
        cid, tag = rnd(16), rnd(8)

        def msg(cseq, auth=None):
            m = (f"REGISTER sip:{a.domain} SIP/2.0\r\n"
                 f"Via: SIP/2.0/UDP {self.lip}:{self.lport};"
                 f"branch=z9hG4bK{rnd(12)}{cseq};rport\r\n"
                 f"Max-Forwards: 70\r\n"
                 f"From: <sip:{a.user}@{a.domain}>;tag={tag}\r\n"
                 f"To: <sip:{a.user}@{a.domain}>\r\n"
                 f"Call-ID: {cid}\r\n"
                 f"CSeq: {cseq} REGISTER\r\n"
                 f"Contact: {self.contact}\r\n"
                 f"Expires: {a.expires}\r\n"
                 f"User-Agent: sip-uas-probe\r\n")
            if auth:
                m += f"Authorization: {auth}\r\n"
            return m + "Content-Length: 0\r\n\r\n"

        self.send(msg(1))
        code, txt = self.wait_response(r"\d\d\d", 5, cid)
        if code is None:
            self.log("FAIL: REGISTER'a yanit gelmedi")
            return False
        if code.startswith("2"):
            self.log("  kayit: 200 OK (challenge'siz)")
            return True
        if code not in ("401", "407"):
            self.log(f"FAIL: REGISTER icin beklenmeyen yanit {code}")
            return False

        m = re.search(r"(?:WWW|Proxy)-Authenticate:\s*Digest\s*(.*)", txt, re.I)
        if not m:
            self.log("FAIL: 401 icinde Digest challenge yok")
            return False
        chal = m.group(1)
        auth = digest_response(
            a.user, a.password,
            re.search(r'realm="([^"]+)"', chal).group(1),
            re.search(r'nonce="([^"]+)"', chal).group(1),
            "REGISTER", f"sip:{a.domain}", chal)
        self.send(msg(2, auth))
        code, _ = self.wait_response(r"\d\d\d", 5, cid)
        if code is None or not code.startswith("2"):
            self.log(f"FAIL: kimlik dogrulamali REGISTER reddedildi ({code})")
            return False
        self.log(f"  kayit: 200 OK ({a.user}@{a.domain})")
        return True

    def wait_response(self, want, timeout, cid=None):
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            txt = data.decode(errors="replace")
            if not txt.startswith("SIP/2.0"):
                continue
            if cid and hdr(txt, "Call-ID") != cid:
                continue
            code = txt.split("\r\n")[0].split()[1]
            if code == "100":
                continue
            if re.match(want, code):
                return code, txt
        return None, None

    # ---------- Gelen cagri ----------
    def wait_invite(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, src = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            txt = data.decode(errors="replace")
            first = txt.split("\r\n")[0]
            if first.startswith("INVITE "):
                # Yanitlari INVITE'in GELDIGI kaynaga gonderiyoruz, kayit
                # sirasinda kullandigimiz proxy adresine degil. Proxy,
                # istegi kendi soketinden iletirken NAT/port farkli olabilir;
                # sabit adrese yanit verildiginde 180/200 OK proxy'nin
                # transaction'ina hic ulasmaz ve arayan taraf NO_ANSWER alir.
                self.peer = src
                self.log(f"  INVITE kaynagi: {src[0]}:{src[1]}")
                return txt
            if first.startswith("OPTIONS "):
                self.peer = src
                self.reply(txt, "200 OK")      # ping'lere nazik davran
        return None

    def reply(self, req, status, sdp=None, add_contact=False):
        # .strip() ZORUNLU: `.` karakteri `\r`'yi de yakalar, `$` ise `\n`'den
        # once eslesir. Strip edilmezse her deger sonunda bir `\r` tasir ve
        # ustune `\r\n` eklendiginde satir `...\r\r\n` olur. Kamailio bunu
        # ayristiramaz ve yaniti sessizce atar:
        #   ERROR: receive_msg(): required headers not found in reply
        # Belirti disaridan "cagrilan taraf hic cevap vermiyor" gibi gorunur
        # (arayan NO_ANSWER alir), oysa yanit gonderilmis ama bozuktur.
        vias = [v.strip() for v in re.findall(r"^Via:\s*(.+)$", req, re.I | re.M)]
        m = (f"SIP/2.0 {status}\r\n"
             + "".join(f"Via: {v}\r\n" for v in vias)
             + f"From: {hdr(req, 'From')}\r\n"
             f"To: {hdr(req, 'To')};tag={self.totag}\r\n"
             f"Call-ID: {hdr(req, 'Call-ID')}\r\n"
             f"CSeq: {hdr(req, 'CSeq')}\r\n")
        rr = [v.strip() for v in
              re.findall(r"^Record-Route:\s*(.+)$", req, re.I | re.M)]
        m += "".join(f"Record-Route: {v}\r\n" for v in rr)
        if add_contact:
            m += f"Contact: {self.contact}\r\n"
        m += "User-Agent: sip-uas-probe\r\n"
        if sdp:
            m += ("Content-Type: application/sdp\r\n"
                  f"Content-Length: {len(sdp)}\r\n\r\n{sdp}")
        else:
            m += "Content-Length: 0\r\n\r\n"
        if self.a.verbose:
            self.log("  --- GONDERILEN ---\n" + m)
        self.s.sendto(m.encode(), self.peer or self.dst)

    def run(self):
        a = self.a
        self.totag = rnd(10)
        self.log(f"--- UAS {a.user}@{a.domain} (SIP {self.lip}:{self.lport}, "
                 f"RTP {a.rtp_port}) ---")
        if not self.register():
            print("RESULT registered=0 answered=0 rtp_in=0")
            return 1
        print("READY", flush=True)   # verify script bu satiri bekler

        self.log(f"  gelen cagri bekleniyor ({a.wait}s)")
        inv = self.wait_invite(a.wait)
        if inv is None:
            self.log("FAIL: sure icinde INVITE gelmedi")
            print("RESULT registered=1 answered=0 rtp_in=0")
            return 1

        rem_ip = rem_port = None
        body = inv.split("\r\n\r\n", 1)
        if len(body) == 2:
            c = re.search(r"^c=IN IP4 (\S+)", body[1], re.M)
            p = re.search(r"^m=audio (\d+)", body[1], re.M)
            if c and p:
                rem_ip, rem_port = c.group(1), int(p.group(1))
        self.log(f"  INVITE alindi; uzak medya {rem_ip}:{rem_port}")

        self.reply(inv, "100 Trying")
        self.reply(inv, "180 Ringing", add_contact=True)
        time.sleep(0.3)

        sdp = (f"v=0\r\no=- 2 2 IN IP4 {self.lip}\r\ns=uas-probe\r\n"
               f"c=IN IP4 {self.lip}\r\nt=0 0\r\n"
               f"m=audio {a.rtp_port} RTP/AVP 0 101\r\n"
               "a=rtpmap:0 PCMU/8000\r\n"
               "a=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n")
        self.reply(inv, "200 OK", sdp=sdp, add_contact=True)
        self.log("  200 OK gonderildi")

        rtp_in = self.media_loop(rem_ip, rem_port, a.media_time)
        self.log(f"  RTP alindi: {rtp_in} paket")

        # BYE'i bekle; gelmezse cagriyi biz kapatmayiz (arayan kapatir).
        end = time.time() + 3
        while time.time() < end:
            try:
                data, _src = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            txt = data.decode(errors="replace")
            if txt.startswith("BYE "):
                self.peer = _src
                self.reply(txt, "200 OK")
                self.log("  BYE alindi, 200 OK dondu")
                break

        ok = rtp_in > 0
        print(f"RESULT registered=1 answered=1 rtp_in={rtp_in}")
        if not ok:
            self.log("FAIL: cagri cevaplandi ama hic RTP gelmedi")
        return 0 if ok else 1

    def media_loop(self, ip, port, seconds):
        """Gelen RTP'yi sayar ve geri yansitir (iki yonlu ses kaniti)."""
        rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        rx.bind(("0.0.0.0", self.a.rtp_port))
        rx.settimeout(0.1)
        got = 0
        end = time.time() + seconds
        while time.time() < end:
            try:
                data, src = rx.recvfrom(2048)
            except socket.timeout:
                continue
            if len(data) >= 12 and data[0] & 0xC0 == 0x80:
                got += 1
                # Yansit: kaynaga geri gonder (symmetric RTP).
                try:
                    rx.sendto(data, src)
                except OSError:
                    pass
        rx.close()
        return got


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--proxy", required=True)
    p.add_argument("--domain", required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--sip-port", type=int, default=45060)
    p.add_argument("--rtp-port", type=int, default=40300)
    p.add_argument("--expires", type=int, default=120)
    p.add_argument("--wait", type=float, default=20.0,
                   help="INVITE beklenecek sure")
    p.add_argument("--media-time", type=float, default=2.0)
    p.add_argument("--verbose", action="store_true",
                   help="gonderilen SIP yanitlarini bas")
    sys.exit(UAS(p.parse_args()).run())


if __name__ == "__main__":
    main()
