#!/bin/bash
cliente="cliente"
ambiente="production"
region="sfo3"
size="s-2vcpu-4gb"

echo ------- Confirme los Datos -------
echo 'Cliente:' && echo $cliente
echo ''
echo 'Ambiente:' && echo $ambiente
echo ''
echo 'Region:' && echo $region
echo ''
echo 'Size:' && echo $size
echo ''
echo ----------------------------------

echo "Estan Correctos?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) break;;
        No ) exit;;
    esac
done

echo [Step 1] ------- Creando Cluster $cliente -------

doctl auth init -o json # Nos authenticamos en Digital Ocean
# Se crea el Cluster indicando el nombre, región, y catacteristicas del pool
doctl kubernetes cluster create cluster-$cliente-$ambiente \
--region $region \
--node-pool="name=pool-$cliente;size=$size;count=1;auto-scale=false;min-nodes=1;max-nodes=1;tag=$cliente" \
-o json

echo [Step 2] ------- Guardando Kubeconfig -------

# se guarda el contexto en nuestra maquina virtual y se le indica que sea el conexto actual
doctl kubernetes cluster kubeconfig save cluster-$cliente-$ambiente --set-current-context=true

echo [Step 3] ------- Obteniendo Nombre y Contexto -------

# Obtenemos el nombre del Cluster para generar el nombre del Contexto
name=$(doctl kubernetes cluster get cluster-$cliente-$ambiente --format Name)
name=${name//Name}
name=${name//$'\n'/}
context="do-${region}-${name}"

echo [Step 4] ------- Creando Secret Docker -------

docker login
kubectl --context $context create secret docker-registry regcred --docker-server=<docker-server> --docker-username=<docker-user> --docker-password=<docker-password> --docker-email=<docker-email>

echo [Step 5] ------- Desplegando Servicios -------

kubectl --context $context apply -k ./

echo [Step 6] ------- Creando Nginx Ingress Controller -------

kubectl --context $context apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.1/deploy/static/mandatory.yaml
kubectl --context $context apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.26.1/deploy/static/provider/cloud-generic.yaml


echo [Step 7] ------- Esperando a Pog Ingress Controller -------

kubectl --context $context wait --all-namespaces --for=condition=ready pod --selector=app.kubernetes.io/name=ingress-nginx --timeout=240s

echo [Step 8] ------- Esperando a External IP -------

external_ip=""
none="<none>"
while [ -z $external_ip ]; do
  echo "Esperando External IP"
  # ip=$(kubectl --namespace=ingress-nginx get service ingress-nginx -o=custom-columns=IP:.status.loadBalancer.ingress[0].ip)
  ip=$(kubectl --context $context get svc --namespace=ingress-nginx -o=custom-columns=IP:.status.loadBalancer.ingress[0].ip)
  ip=${ip//IP} ## Remueve la palabra IP del ip y solo queda el 0.0.0.0
  ip=${ip//$'\n'/} ## Remueve todos los espacios
  if [ "$ip" != "$none" ]; then 
    external_ip=$ip
  fi
  [ -z "$external_ip" ] && sleep 10
done 


echo [Step 9] ------- Creando Records -------

doctl compute domain records create <dominio> --record-name <sub-dominio> --record-type A --record-data $external_ip # Aqui quede

echo [Step 10] ------- Aplicando Cert-Manager -------

kubectl --context $context create namespace cert-manager
kubectl --context $context apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.12.0/cert-manager.yaml

echo [Step 11] ------- Esperando a Pod WebHook -------

while [[ $(kubectl --context $context get pods -l app=webhook --namespace cert-manager -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "Esperando al Pods webhook" && sleep 1; done
kubectl --context $context get pods --namespace cert-manager


echo [Step 12] ------- Creando Certificados HTTPS letsencrypt Staging-------

kubectl --context $context apply -f ./letsencrypt/staging_issuer.yaml

echo [Step 13] ------- Aplicando Ingress Yaml Staging -------

kubectl --context $context apply -f ./ingress-staging.yaml

echo [Step 14] ------- Esperando Certificado Staging -------

while [[ $(kubectl --context $context get certificate <nombre-certificado> --namespace default -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
do echo "Esperando Staing Certificado" && sleep 1; done
kubectl --context $context get certificate

echo [Step 15] ------- Creando Certificados HTTPS letsencrypt Prod-------

kubectl --context $context apply -f ./letsencrypt/prod_issuer.yaml

echo [Step 16] ------- Aplicando Ingress Yaml Staging -------

kubectl --context $context apply -f ./ingress-prod.yaml

echo [Step 17] ------- Esperando Certificado Production -------

while [[ $(kubectl --context $context get certificate <nombre-certificado> --namespace default -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
do echo "Esperando Production Certificado" && sleep 1; done
kubectl --context $context get certificate

echo ----------Info--------------
echo 'Nombre Cluster:' && echo $name
echo 'Contexto:' && echo $context
echo 'External IP:' && echo $external_ip
echo ----------------------------


read cliente