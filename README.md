wazo-nginx
==========

wazo-nginx is a Debian package that provides a basic configuration for the
nginx server used by Wazo.

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

# confd users cache

`sites-available/wazo-confd-cache` adds a loopback-only listener
(`127.0.0.1:9487` and `[::1]:9487`) in front of wazo-confd. It caches
`GET /1.1/users` for 60 seconds, keyed on the `Wazo-Tenant` header and the
full URI. Requests with a `uuid` filter and all other paths go to confd
without cache. The `X-Cache-Status` response header shows `HIT`, `MISS`,
`BYPASS`, `STALE` or `UPDATING`.

Only wazo-dird must use it. A cache hit does not reach confd, so confd does not
check the token. The cache is for one tenant and holds directory data (names,
numbers, e-mail addresses) in `/var/cache/nginx/wazo-confd-users`.

To use it, set `confd.port` to `9487` in the dird `wazo` source and restart
wazo-dird. To stop, set the port back to `9486`, restart wazo-dird, and remove
`/etc/nginx/sites-enabled/wazo-confd-cache`.

Test with docker: `tests/test_users_cache.sh [nginx-image]`.
