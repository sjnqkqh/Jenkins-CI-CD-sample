apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  name: ${USER_NAME}-myfirst-ingress
  namespace: ${NAMESPACE}
spec:
  ingressClassName: public-nginx
  rules:
  - host: ${USER_NAME}-ingress.skala25a.project.skala-ai.com
    http:
      paths:
      - backend:
          service:
            name: ${USER_NAME}-myfirst-api-server
            port:
              number: 8080
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - '${USER_NAME}-ingress.skala25a.project.skala-ai.com'
    secretName: ${USER_NAME}-ingress-project-tls-cert
