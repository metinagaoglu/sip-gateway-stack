FROM nginx:1.27-alpine

# openssl: sertifika CALISMA ANINDA uretilir, cunku SAN degeri EXTERNAL_IP'ye
# baglidir ve build-time'da bilinmez. Imaja gomulu bir sertifika farkli
# makinelerde yanlis SAN tasir ve tarayici reddeder.
RUN apk add --no-cache openssl

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY index.html client.js /usr/share/nginx/html/
COPY vendor/ /usr/share/nginx/html/vendor/

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8443/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
