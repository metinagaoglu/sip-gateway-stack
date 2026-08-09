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

    def ack(self, cseq, branch, to_hdr, in_dialog):
        # 2xx'e ACK yeni bir transaction'dir (yeni branch); 407'ye ACK ise
        # ayni branch'i kullanmak ZORUNDADIR, yoksa proxy 407'yi retransmit eder.
        return (
            f"ACK {self.ruri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.lip}:{self.lport};branch={branch};rport\r\n"
            f"Max-Forwards: 70\r\n"
            f"From: <sip:{self.a.user}@{self.a.domain}>;tag={self.tag}\r\n"
            f"To: {to_hdr}\r\n"
            f"Call-ID: {self.cid}\r\n"
            f"CSeq: {cseq} ACK\r\n"
            "Content-Length: 0\r\n\r\n"
        )

    def bye(self, cseq, to_hdr):
        return (
            f"BYE {self.ruri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.lip}:{self.lport};branch={self.branch()};rport\r\n"
            f"Max-Forwards: 70\r\n"
            f"From: <sip:{self.a.user}@{self.a.domain}>;tag={self.tag}\r\n"
            f"To: {to_hdr}\r\n"
            f"Call-ID: {self.cid}\r\n"
            f"CSeq: {cseq} BYE\r\n"
            "Content-Length: 0\r\n\r\n"
        )

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
            if code == "100":
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
        self.s.send(self.ack(1, b1, to_hdr, False).encode())

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
        self.log("  4) ACK (200 OK icin)")
        self.s.send(self.ack(2, self.branch(), to_hdr, True).encode())

        self.log(f"  5) cagri {a.hold}s ayakta tutuluyor")
        time.sleep(a.hold)

        # 3) BYE ile kapat. Bu adim ayni zamanda "cagri sonlandirmada
        #    FreeSWITCH cokuyor mu" suphesini de sinar.
        self.log("  6) BYE")
        self.s.send(self.bye(3, to_hdr).encode())
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
    sys.exit(Probe(p.parse_args()).run())


if __name__ == "__main__":
    main()
