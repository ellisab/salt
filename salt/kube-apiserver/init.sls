include:
  - ca-cert
  - cert
  - haproxy
  - kubernetes-common
  - kubernetes-common.serviceaccount-key

{% from '_macros/certs.jinja' import certs with context %}
{{ certs("kube-apiserver",
         pillar['ssl']['kube_apiserver_crt'],
         pillar['ssl']['kube_apiserver_key'],
         cn = grains['nodename'],
         o = pillar['certificate_information']['subject_properties']['O']) }}

kube-apiserver:
  pkg.installed:
    - pkgs:
      - iptables
      - kubernetes-master
  caasp_retriable.retry:
    - name: iptables-kube-apiserver
    - target: iptables.append
    - retry:
        attempts: 2
    - table:      filter
    - family:     ipv4
    - chain:      INPUT
    - jump:       ACCEPT
    - match:      state
    - connstate:  NEW
    - dports:
      - {{ pillar['api']['int_ssl_port'] }}
    - proto:      tcp
    - require:
      - sls:      kubernetes-common
  file.managed:
    - name:       /etc/kubernetes/apiserver
    - source:     salt://kube-apiserver/apiserver.jinja
    - template:   jinja
  service.running:
    - enable:     True
    - require:
      - caasp_retriable: iptables-kube-apiserver
      - sls:             ca-cert
      - caasp_retriable: {{ pillar['ssl']['kube_apiserver_crt'] }}
      - x509:            {{ pillar['paths']['service_account_key'] }}
      - file:            /etc/kubernetes/audit-policy.yaml
      - file:            /var/log/kube-apiserver
    - watch:
      - sls:             kubernetes-common
      - file:            kube-apiserver
      - file:            /etc/kubernetes/audit-policy.yaml
      - sls:             ca-cert
      - caasp_retriable: {{ pillar['ssl']['kube_apiserver_crt'] }}
      - x509:            {{ pillar['paths']['service_account_key'] }}

/var/log/kube-apiserver:
  file.directory:
    - user: kube
    - group: kube
    - dirmode: 755
    - filemode: 644
    - require:
      - pkg: kube-apiserver

/etc/kubernetes/audit-policy.yaml:
  file.managed:
    - contents_pillar: api:audit:log:policy

#
# Wait for (in order)
# 1. the local ("internal") API server
# 2. the API-through-haproxy, to be answering on any location. Even if our
#    local instance is already up, it could happen that HAProxy did not
#    yet realize it's up, so let's wait until HAProxy agrees with us.
#
{%- set api_server = 'api.' + pillar['internal_infra_domain'] %}

{%- for port in ['int_ssl_port', 'ssl_port'] %}

kube-apiserver-wait-port-{{ port }}:
  caasp_retriable.retry:
    - target:     caasp_http.wait_for_successful_query
    - name:       {{ 'https://' + api_server + ':' + pillar['api'][port] }}/healthz
    - wait_for:   300
    # retry just in case the API server returns a transient error
    - retry:
        attempts: 3
    - ca_bundle:  {{ pillar['ssl']['ca_file'] }}
    - status:     200
    - opts:
        http_request_timeout: 30
    - watch:
      - service: kube-apiserver

{% endfor %}
