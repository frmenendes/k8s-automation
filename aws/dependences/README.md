# Script de Configuração básica do Cluster EKS

Este script automatiza o processo de configuração e instalação de várias ferramentas em um cluster Amazon EKS (Elastic Kubernetes Service). Ele verifica a presença de ferramentas essenciais, autentica com a AWS, configura a AWS CLI e instala várias aplicações via Helm.

# Ferramentas necessárias

- aws: AWS CLI para interação com a Amazon Web Services.
- helm: Um pacote Kubernetes para gerenciar aplicações.
- kubectl: Ferramenta CLI para interagir com o Kubernetes.
- eksctl: Uma ferramenta CLI para criar e gerenciar clusters no Amazon EKS.

# Dependências

- Credenciais da AWS configuradas (geralmente definidas em ~/.aws/credentials).
- Um cluster EKS já criado.

# Como usar

1. Clone o Repositório:
```bash
git clone <URL_DO_REPOSITORIO>
cd <DIRETORIO_DO_SCRIPT>
```
2. Modifique as variáveis:
Antes de executar o script, certifique-se de modificar as variáveis de acordo com suas necessidades, como CLUSTER_NAME, REGION, ACCOUNT_ID, DOMAIN, AWS_ACCESS_KEY, AWS_SECRET_KEY etc.

3. Torne o script executável:
```bash
chmod +x <NOME_DO_SCRIPT>.sh
```

4. Execute o script:
```bash
./<NOME_DO_SCRIPT>.sh
```

# Funcionalidades

- Verifica se as ferramentas necessárias estão instaladas.
- Autentica com a AWS e configura a AWS CLI.
- Instala e verifica o funcionamento do Metrics Server, cert-manager, External-DNS, AWS Load Balancer Controller, kube-state-metrics e Prometheus.
- O script também contém funcionalidades para instalar o Grafana e conceder ao usuário root da AWS acesso administrativo ao cluster, mas essas partes estão comentadas por padrão.

# Informação Importante

O cluster precisa de permissão no Route53 para criar os registros. Após a criação do cluster com o eksctl, não esqueça de conceder acessos a role do nodegroup e do cluster.
# Troubleshooting

Se ocorrer um erro durante a execução, o script imprimirá "Erro detectado durante a operação!" e encerrará a execução. Em tal caso, verifique a saída para obter detalhes sobre a causa do erro e ajuste o script ou o ambiente conforme necessário.

# Contribuições

Sinta-se à vontade para contribuir com melhorias ou relatar problemas no GitHub.
