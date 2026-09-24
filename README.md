wazo-nginx
==========

wazo-nginx is a Debian package that provides a basic configuration for the
nginx server used by Wazo.

# Certificates

The certificate served on port 443 is configured in
`/etc/nginx/snippets/wazo-certificate.conf`, so it can be replaced without
modifying the `wazo` site.

Port 80 serves ACME HTTP-01 challenges from `/var/www/html` and redirects
everything else to https. To use a Let's Encrypt certificate with certbot:

```
certbot certonly --webroot -w /var/www/html -d wazo.example.com \
  --deploy-hook 'systemctl reload nginx'
```

Then point `/etc/nginx/snippets/wazo-certificate.conf` to it:

```
ssl_certificate /etc/letsencrypt/live/wazo.example.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/wazo.example.com/privkey.pem;
```

and reload nginx. Renewals (`certbot renew`) then work unattended.

# Logs

External requests (ports 80 and 443) are logged in `wazo.access.log`, internal
service-to-service requests (loopback only, port 80) in `wazo-internal.access.log`.

The default Wazo log format add additional information about
response time and status.

```
log_format main
    '$remote_addr - $remote_user [$time_local] "$request" '
    '$status $body_bytes_sent "$http_referer" "$http_user_agent" "$sent_http_x_powered_by" '
    '$request_length $msec $request_time $upstream_addr '
    '$upstream_response_length $upstream_response_time $upstream_status';
```

| Placeholder               | Description                                                       |
|---------------------------|-------------------------------------------------------------------|
| $remote_addr              | the source IP address of the client                               |
| $remote_user              | user name supplied with the Basic authentication                  |
| $time_local               | local time in the Common Log Format                               |
| $request                  | full original request line                                        |
| $status                   | response status                                                   |
| $body_bytes_sent          | number of body bytes sent to a client                             |
| $http_referer             | value of the Referer header                                       |
| $http_user_agent          | value of User-Agent header                                        |
| $sent_http_x_powered_by   | service name                                                      |
| $request_length           | request length (including request line, header, and request body) |
| $mesc                     | time in seconds with a milliseconds at the time of the log write  |
| $request_time             | request processing time in seconds with a milliseconds resolution |
| $upstream_addr            | the IP address and port of the upstream server                    |
| $upstream_response_length | the length of the response obtained from the upstream server      |
| $upstream_response_time   | time spent on receiving the response from the upstream server     |
| $upstream_status          | status code of the response obtained from the upstream server     |

## GoAccess log format

Logs can be analyzed with [GoAccess](https://goaccess.io) using the following
time, date and log format :

```
time-format %H:%M:%S

date-format %d/%b/%Y

log-format %h %^ %e [%d:%t %^] "%r" %s %b "%R" "%u" "%^" %^ %^ %^ %v %^ %T %^
```

Live report command line example :

```
goaccess --real-time-html --date-format '%d/%b/%Y' --time-format '%H:%M:%S' \
  --log-format '%h %^ %e [%d:%t %^] "%r" %s %b "%R" "%u" "%^" %^ %^ %^ %v %^ %T %^' \
  /var/log/nginx/wazo.access.log
```
