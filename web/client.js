'use strict';

const el = (id) => document.getElementById(id);
const logBox = el('log');

function log(msg) {
  const t = new Date().toISOString().substring(11, 23);
  logBox.textContent += `${t}  ${msg}\n`;
  logBox.scrollTop = logBox.scrollHeight;
}

let ua = null;
let session = null;

function resetCall() {
  session = null;
  el('remote').srcObject = null;
  el('call').disabled = false;
  el('hangup').disabled = true;
}

el('register').addEventListener('click', () => {
  if (ua) {
    log('UA zaten var — sayfayi yenileyip tekrar deneyin');
    return;
  }

  const user = el('user').value.trim();
  const domain = el('domain').value.trim();

  // WSS adresi sayfanin origin'inden turetilir. Sayfa ve WebSocket ayni
  // host:port uzerinde oldugu icin tarayicida TEK sertifika istisnasi yeter,
  // ve HTML'e hicbir ortam degiskeni render etmemiz gerekmez.
  const wsUrl = `wss://${location.host}/ws`;
  log(`WebSocket: ${wsUrl}`);

  ua = new JsSIP.UA({
    sockets: [new JsSIP.WebSocketInterface(wsUrl)],
    uri: `sip:${user}@${domain}`,
    authorization_user: user,
    password: el('pass').value,
    session_timers: false,
    register: true,
  });

  ua.on('connected', () => log('WebSocket bagli'));
  ua.on('disconnected', (e) => log(`WebSocket koptu (${e && e.error ? 'hata' : 'normal'})`));
  ua.on('registered', () => {
    log('REGISTER 200 OK');
    el('call').disabled = false;
  });
  ua.on('unregistered', () => {
    log('kayit dusuldu');
    el('call').disabled = true;
  });
  ua.on('registrationFailed', (e) => log(`REGISTER basarisiz: ${e.cause}`));

  ua.start();
});

el('call').addEventListener('click', () => {
  const target = `sip:${el('target').value.trim()}@${el('domain').value.trim()}`;
  log(`ARIYOR ${target}`);

  session = ua.call(target, {
    // Mikrofon izni ICE icin ON KOSULDUR: izin verilmeden Chrome yerel
    // IP'leri saklar ve host candidate yerine cozumlenemeyen bir .local mDNS
    // adi yayinlar. FreeSWITCH o adi cozemez, connectivity check hic
    // baslamaz ve belirti "cagri kuruluyor, ses yok" olur.
    mediaConstraints: { audio: true, video: false },
    // STUN gereksiz: sunucunun adresi zaten erisilebilir, baglantiyi tarayici
    // baslatir ve FreeSWITCH symmetric RTP ile kaynaga geri gonderir. STUN
    // yalnizca ICE toplama suresini uzatir.
    pcConfig: { iceServers: [] },
  });

  // SDP logu tanida zorunlu: DTLS fingerprint'i, ICE candidate'lari ve medya
  // profilinin (UDP/TLS/RTP/SAVPF) iki tarafta ne oldugunu baska yerden
  // goremiyoruz.
  session.on('sdp', (e) => log(`SDP ${e.originator} ${e.type}:\n${e.sdp}`));

  session.on('peerconnection', (e) => {
    const pc = e.peerconnection;
    pc.addEventListener('track', (ev) => {
      log(`medya track alindi: ${ev.track.kind}`);
      el('remote').srcObject = ev.streams[0];
    });
    pc.addEventListener('iceconnectionstatechange', () => {
      log(`ICE durumu: ${pc.iceConnectionState}`);
    });
  });

  session.on('progress', () => log('progress (180/183)'));
  session.on('accepted', () => log('200 OK'));
  session.on('confirmed', () => log('ACK gonderildi, cagri kuruldu'));
  session.on('failed', (e) => {
    log(`cagri basarisiz: ${e.cause}`);
    resetCall();
  });
  session.on('ended', (e) => {
    log(`cagri bitti: ${e.cause}`);
    resetCall();
  });

  el('call').disabled = true;
  el('hangup').disabled = false;
});

el('hangup').addEventListener('click', () => {
  if (session) {
    session.terminate();
  }
});
