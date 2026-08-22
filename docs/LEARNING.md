# Guia de estudo — cadeia de suprimentos de software

Material em pt-BR para operar, quebrar e consertar este pilar. A documentação em inglês (`README.md`,
`docs/slsa.md`) é a versão de portfólio; esta aqui é a de estudo.

## 1. Três perguntas diferentes

O erro mais comum é achar que "assinar a imagem" resolve tudo. São três perguntas independentes:

| Pergunta | Artefato | Ferramenta |
|---|---|---|
| **Quem construiu isso?** | assinatura | `cosign sign` (keyless) |
| **O que tem dentro?** | SBOM | Syft → SPDX JSON, anexado com `cosign attest` |
| **Como foi construído?** | provenance | `actions/attest-build-provenance` |

Uma assinatura sem SBOM diz que alguém confiável entregou uma caixa fechada. Um SBOM sem assinatura é um arquivo de
texto que qualquer um reescreve. A provenance é o que liga a caixa ao commit que a gerou. Se faltar qualquer um dos
três, o job `verify` derruba o build.

## 2. Por que keyless (Fulcio + Rekor)

Assinatura tradicional exige uma chave privada. Alguém guarda, alguém rotaciona, e no dia que vaza a chave assina
**qualquer coisa** — inclusive retroativamente.

No modelo keyless não existe chave para guardar:

1. O workflow apresenta o token OIDC dele ao **Fulcio**.
2. O Fulcio devolve um certificado válido por ~10 minutos, amarrado à identidade
   `https://github.com/slackerwx/<repo>/.github/workflows/<arquivo>@refs/heads/main`.
3. A assinatura e o certificado vão para o **Rekor**, um log público append-only.
4. Na verificação você não pergunta "foi assinado com a chave certa?", e sim **"foi assinado por qual identidade?"**.

O que mudou: o problema deixou de ser gestão de segredo e passou a ser **gestão de quem consegue dar merge na
`main`**. Isso é uma troca consciente — e uma pergunta boa de entrevista: *"se não tem chave, o que um atacante
precisa comprometer para conseguir uma assinatura válida?"* Resposta: a branch protection.

## 3. O que é SLSA, e por que a gente para no L2

| Nível | Exige | Aqui |
|---|---|---|
| L1 | provenance existe e está disponível | ✅ |
| L2 | provenance assinada, gerada por serviço de build hospedado | ✅ é o que a gente reivindica |
| L3 | provenance gerada por builder **isolado**, que o build não consegue forjar | ❌ |

O buraco do L3 é honesto e está escrito em `docs/slsa.md`: a nossa provenance é produzida por um *step* no mesmo job
do build. Um build comprometido está em posição de influenciar o que a provenance diz sobre ele mesmo. Subir para L3
exige o `slsa-github-generator`, que constrói dentro de um reusable workflow separado — mais complexidade do que um
homelab justifica, e que não muda nada na história do admission control.

## 4. Por que `:latest` quebra a cadeia

Uma tag é um ponteiro mutável. `ghcr.io/slackerwx/app:latest` hoje e amanhã podem ser manifests diferentes.

- A assinatura é feita sobre o **digest** (`@sha256:…`), não sobre a tag. Assinar `:latest` assina o conteúdo de
  agora; amanhã a tag aponta para outro lugar e a assinatura não acompanha.
- Por isso o `reusable-container.yml` assina sempre por digest, e por isso o `disallow-latest-tag` do
  `platform-policies` existe: sem tag imutável, "essa imagem foi verificada" vira uma frase sem sujeito.
- O homelab usa `sha7` (7 caracteres do commit) como tag de deploy justamente para ter um ponteiro estável e legível.

## 5. Como um auditor verifica sem confiar em você

Passo a passo que qualquer pessoa de fora executa (ver `docs/slsa.md` para o detalhe):

1. Puxa a imagem **por digest** — conteúdo endereçado, ninguém troca por baixo.
2. `cosign verify` com o regexp de identidade que **ela** escolher.
3. Procura a entrada no Rekor (`rekor-cli search --sha <digest>`) — log público que a gente não opera.
4. `cosign verify-attestation --type spdxjson` e lê o SBOM.
5. `gh attestation verify` e lê `resolvedDependencies` para chegar no commit.

Em nenhum momento ela precisa acreditar em nós. Esse é o produto inteiro.

---

# Exercícios: quebrar e consertar

Todos partem de uma imagem já publicada e assinada. Guarde a referência por digest:

```bash
IMG=ghcr.io/slackerwx/platform-supply-chain-hello@sha256:<digest>
export GHCR_TOKEN=<PAT com read:packages>
./scripts/verify-image.sh "$IMG"     # deve passar antes de você quebrar qualquer coisa
```

## Exercício 1 — mexer na imagem e ver a assinatura cair

```bash
brew install crane
crane mutate "$IMG" --env INJETADO=1 --tag ghcr.io/slackerwx/platform-supply-chain-hello:adulterada
./scripts/verify-image.sh ghcr.io/slackerwx/platform-supply-chain-hello:adulterada
```

**Sintoma esperado:** `Error: no matching signatures`. O `crane mutate` gerou um manifest novo, com digest novo — e
não existe assinatura para esse digest.

**O que isso ensina:** a assinatura não protege a imagem de ser modificada; ela torna a modificação **detectável**.
É a diferença entre um cadeado e um lacre.

**Consertar:** apague a tag adulterada no GHCR. Nada mais a fazer — o original nunca foi tocado.

## Exercício 2 — introduzir uma CVE crítica e ver o gate barrar

Em `example/hello-supply-chain/pyproject.toml`, adicione uma dependência velha e sabidamente vulnerável:

```toml
dependencies = ["pyyaml==5.3.1"]   # CVE-2020-14343, execução arbitrária de código
```

Rode `uv lock`, faça commit numa branch e abra um PR.

**Sintoma esperado:** o job `container` falha no step *"Fail on vulnerabilities above the gate"*. Com o gate padrão
em `critical`, uma CVE de severidade CRITICAL derruba o build; o SARIF sobe para a aba Security mesmo assim.

**O que isso ensina:** o SBOM não é enfeite — o Grype escaneia **o SBOM**, não a imagem de novo. O inventário que
foi escaneado é comprovadamente o mesmo que foi atestado.

**Consertar:** remover a dependência (ou subir para uma versão corrigida) e refazer o `uv lock`.

## Exercício 3 — publicar uma imagem por fora do workflow

```bash
docker build -t ghcr.io/slackerwx/rebelde:v1 .    # de qualquer máquina, na mão
docker push ghcr.io/slackerwx/rebelde:v1
kubectl run rebelde --image=ghcr.io/slackerwx/rebelde:v1 -n default
```

**Sintoma esperado:** com `verify-images-slackerwx` em **Audit**, o pod sobe e aparece um `PolicyReport` com
`result: fail`; o Policy Reporter manda o webhook para o n8n. Com a policy em **Enforce**, o admission recusa o pod
com `image is not signed`.

```bash
kubectl get policyreport -A | grep -i rebelde
kubectl describe policyreport -n default | sed -n '/verify-images/,+10p'
```

**O que isso ensina:** a assinatura só vira controle quando alguém **checa**. Enquanto está em Audit, ela é
telemetria; em Enforce, é fronteira. E é por isso que a ordem do checklist importa: migrar o finops **antes** de
ligar o Enforce, senão o próprio cluster para.

**Consertar:** `kubectl delete pod rebelde` e apagar o pacote no GHCR.

## Exercício 4 — apagar a attestation e ver o `verify` quebrar

```bash
cosign clean --type attestation "$IMG"
./scripts/verify-image.sh "$IMG"
```

**Sintoma esperado:** o check `cosign signature` continua OK, mas `SBOM attestation (spdx)` falha com
`no matching attestations`. Reexecute o workflow no GitHub e o job `verify` fica vermelho pelo mesmo motivo.

**O que isso ensina:** assinatura e attestation são objetos **separados** no registry (tags `sha256-….sig` e
`sha256-….att`). Dá para ter um sem o outro — e um pipeline que só checa a assinatura não perceberia.

**Consertar:** rode o workflow de novo na `main`; ele reanexa a attestation ao mesmo digest.

## Exercício 5 — apertar o gate para `high` e medir o ruído

Em `.github/workflows/ci.yml`, troque `fail_on_severity: critical` por `high`, abra um PR e observe.

**Sintoma esperado:** o build passa a falhar por CVEs HIGH que vieram da imagem base `python:3.12.14-slim` e que
não têm nada a ver com o seu código. Anote quantas.

**O que isso ensina:** o custo real de um gate rígido não é técnico, é organizacional — a equipe aprende a ignorar
o vermelho. A pergunta certa não é "qual o gate mais seguro?", e sim "qual gate a equipe vai respeitar?". Com VEX
(no backlog) daria para suprimir CVE não explorável e aí sim apertar.

**Consertar:** voltar para `critical`, ou subir a imagem base (`python:3.12.x-slim` mais nova) e medir de novo.

## Exercício 6 — quebrar o contrato de identidade

Em `.github/workflows/ci.yml`, mude o `container` para rodar numa branch que não seja `main` e force um push
assinado a partir dela (ou simplesmente rode `cosign verify` trocando o regexp para exigir `refs/heads/producao`).

**Sintoma esperado:** `none of the expected identities matched what was in the certificate`.

**O que isso ensina:** o regexp de identidade é o **contrato** entre este repo e o `platform-policies`. Ele aparece
em três lugares — no job `verify`, no `scripts/verify-image.sh` e na ClusterPolicy do Kyverno. Se um deles derivar,
a cadeia continua "verde" mas deixou de significar a mesma coisa. Vale reler `§5 Interfaces` da spec.

---

## Para onde levar isso numa entrevista

- *"Como você garante que a imagem em produção veio do seu código?"* → assinatura keyless + provenance + admission
  control; e mostre o `verify-image.sh` rodando.
- *"Qual a diferença entre SBOM e scan de vulnerabilidade?"* → inventário vs. consulta ao inventário; o scan é uma
  fotografia com data, o SBOM é o que permite reescanear amanhã sem rebuildar.
- *"Onde seu pipeline ainda é fraco?"* → L3 não atingido, gate em `critical`, sem VEX. Saber a própria limitação
  vale mais do que fingir cobertura total.
