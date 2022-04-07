FROM alpine:edge

RUN apk update
RUN apk add grafana prometheus supervisor
RUN mkdir -p /run/supervisord/ /var/log/supervisord
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY supervisor.conf /etc/supervisor.conf
COPY grafana.ini /etc/grafana.ini
ADD provisioning /etc/grafana/provisioning
ADD dashboards /etc/grafana/dashboards

CMD ["supervisord", "-c", "/etc/supervisor.conf"]
