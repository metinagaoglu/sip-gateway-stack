# SIP Gateway Stack (Kamailio + FreeSWITCH)

A minimal distributed SIP gateway stack using **Kamailio** as the SIP proxy and **FreeSWITCH** as backend media servers.  
This setup is containerized with Docker for easy testing, development, and experimentation.

---

## 🧩 Architecture

```
           +----------------+
           |   Kamailio     |
           |  (SIP Proxy)   |
           +----------------+
                  |
        -------------------------
        |                       |
+----------------+     +----------------+
|  FreeSWITCH 1  |     |  FreeSWITCH 2  |
|  (Media GW)    |     |  (Media GW)    |
+----------------+     +----------------+
```

Kamailio handles SIP registration, authentication, and load balancing.  
SIP INVITE requests are distributed between the FreeSWITCH nodes.

---

## ⚙️ Components

| Service | Description |
|----------|-------------|
| **Kamailio** | SIP proxy, registration/authentication, dispatcher for FreeSWITCH |
| **FreeSWITCH 1/2** | Media servers handling calls and RTP |
| **PostgreSQL** | User and dispatcher database for Kamailio |
| **Redis** | Optional caching (for auth or presence modules) |

---

## 🚀 Running

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/sip-gateway-stack-sample.git
   cd sip-gateway-stack-sample
   ```

2. Start the stack:
   ```bash
   docker-compose up -d
   ```

3. Check container status:
   ```bash
   docker ps
   ```

Kamailio will be listening on UDP **5060** by default.

---

## 🧪 Testing

You can register SIP clients such as **Zoiper**, **Linphone**, or **MicroSIP** to Kamailio:

- **SIP Server**: `sip:localhost:5060`
- **Username**: your test user (in PostgreSQL `subscriber` table)
- **Password**: your test password

Once registered, Kamailio will route INVITE requests to FreeSWITCH nodes based on the dispatcher configuration.

---

## 🗂️ File Structure

```
.
├── kamailio/
│   ├── kamailio.cfg
│   ├── dispatcher.list
│   └── Dockerfile
├── freeswitch/
│   ├── Dockerfile
│   └── conf/
├── postgres/
│   └── init.sql
├── redis/
├── docker-compose.yml
└── README.md
```

---

## 🧰 Useful Commands

```bash
# Access Kamailio container shell
docker exec -it kamailio /bin/bash

# Check Kamailio logs
docker logs -f kamailio

# Access PostgreSQL
docker exec -it postgres psql -U kamailio -d kamailio
```

---

## 📖 Notes

- Kamailio config file: `/etc/kamailio/kamailio.cfg`
- Dispatcher list: `/etc/kamailio/dispatcher.list`
- Each FreeSWITCH node can be customized to handle specific dialplans or tenants.
- This setup is for development and demo purposes only.

---

## 🧑‍💻 License

MIT License © 2025  
Created for learning and prototyping SIP/VoIP gateway topologies.
