# Financeiro DPR

Backoffice da DPR Construtora para o **controle financeiro das casas**: o que
hoje e preenchido na planilha (uma aba por casa, com o carne de parcelas)
passa a ser preenchido aqui, num sistema com login, e vai **para as mesmas
tabelas** que a Central do Cliente le. O cliente ve o extrato na Central sem
nenhuma sincronizacao no meio. Mais um campo que a planilha nao tinha: o
**boleto do mes**, por parcela.

Mesmo padrao do Central, do CRM e do painel de obras: uma pagina
(`index.html`), banco e login no Supabase, sem etapa de build, publicado pela
Vercel.

## O que tem

| Tela | O que faz |
|---|---|
| Entrar | E-mail e senha do Supabase (o mesmo login da Central, do CRM e do painel de obras). "Esqueci a senha" manda o link |
| Sem acesso | Login que existe mas nao foi liberado para o financeiro. Diz qual e-mail liberar |
| Casas | Todas as casas, agrupadas por empreendimento, com comprador, situacao do contrato, saldo devedor, parcelas pagas e proximo vencimento. Busca por nome, unidade ou empreendimento; filtros por empreendimento e situacao. "Nova casa" |
| Ficha da casa | O **cabecalho da aba**: empreendimento, unidade, comprador, situacao do contrato, data de assinatura, valor da venda, financiamento proposto, FGTS proposto e saldo devedor atualizado. Embaixo, a **tabela de parcelas**, com as mesmas colunas da planilha (data, tipo, comissao, saldo da construtora, INCC %, INCC do mes, saldo corrigido, parcela construtora, IGPM, parcela corrigida, amortizacao, pago, saldo devedor atualizado) e a coluna nova **Boleto do mes** (PDF). Adicionar parcela, gerar varias de uma vez, **colar da planilha** (copia a tabela com a linha de cabecalho e cola), excluir |

O que vai para o banco e exatamente o que a sincronizacao da planilha gravava
(mesmas colunas, mesmos nomes). Nada precisa mudar na Central para ela ler.

## Como colocar no ar

### 1. Banco (Supabase, o mesmo projeto do Central DPR)

Supabase > SQL Editor > New query > colar `sql/001_financeiro.sql` inteiro >
Run. Pode rodar mais de uma vez. Precisa do `sql/001_extrato_cliente.sql` da
Central ja rodado (as tabelas `unidades`, `parcelas` e `vinculos`).

O que ele faz:

- cria `fin_liberacoes` (quem entra), `fin_tem_acesso()` e `fin_perfil()`;
- acrescenta `parcelas.boleto_caminho` (o boleto) e
  `unidades.gerida_no_financeiro` (a casa passou a ser preenchida aqui);
- da a equipe do financeiro o direito de ler e escrever `unidades` e
  `parcelas` (o cliente continua lendo so a casa dele);
- cria o bucket **privado** `boletos` no Storage, com as travas: a equipe
  sobe, abre e tira; o cliente abre so os boletos da casa dele.

### 2. Quem entra

Supabase > Table Editor > `fin_liberacoes`. Todo login aparece la sozinho.
Escreva `liberado` na coluna `liberado` da pessoa e ela entra; apague a
palavra, ou escreva `nao`, e ela perde o acesso. A coluna `resultado` mostra
o que o banco fez. Quem e **gestor do painel de obras** entra sem precisar
disso.

A pessoa precisa ter login no Supabase: cria a conta na Central, no CRM ou
no painel de obras, e depois voce escreve `liberado` aqui. (O financeiro nao
tem "Criar conta" de proposito: ninguem se cadastra num backoffice.)

### 3. Vercel

Projeto novo no time `tecdpr`, ligado a este repositorio, sem variavel de
ambiente nenhuma (a chave que esta no `index.html` e a publicavel, feita para
o navegador; o que protege os dados sao as travas do banco). Producao pela
`main`; cada branch ganha um preview.

## A planilha e o financeiro, juntos

Enquanto as duas coisas existirem: a casa que for **salva no financeiro**
fica marcada (`gerida_no_financeiro`) e a sincronizacao da planilha
(`api/sincronizar` da Central) **nao mexe mais nela**, para nao desfazer o
que a equipe gravou. As outras continuam vindo da planilha. Assim da para
migrar casa por casa: abra a casa no financeiro, confira (ou cole a tabela da
planilha), salve, e dali em diante ela e preenchida aqui.

## O boleto do mes

Na ficha, cada parcela tem "Anexar PDF". O arquivo vai para o bucket
`boletos`, na pasta da casa, e o caminho fica em `parcelas.boleto_caminho`.
A Central mostra o botao **Boleto** nas parcelas que tem arquivo e abre um
link assinado, que vale alguns minutos (o bucket e privado: ninguem abre
boleto de outra casa).

### O boleto vai para o WhatsApp do cliente

Na ficha da casa aparece o campo **WhatsApp do comprador**; a pessoa digita
como quiser, `(85) 99999-9999`, e o banco guarda so numeros com o 55 na
frente. Quando um boleto e anexado, o banco avisa o n8n, que manda o PDF para
o WhatsApp do comprador pela API oficial da Meta e grava a hora em
`parcelas.boleto_enviado_em`; a linha da parcela mostra o selo **Enviado**.
Casa sem telefone: o boleto fica so na Central, e o aviso ao anexar diz isso.
Trocar ou tirar o PDF zera o selo.

Para ligar, nesta ordem:

1. **Banco:** rode `sql/002_whatsapp.sql` (as duas colunas) e depois
   `sql/003_aviso_n8n.sql` (a tabela `fin_config` e o gatilho
   `parcelas_boleto_para_n8n`, que faz o POST com `pg_net`). O gatilho so
   dispara quando `boleto_caminho` muda para um PDF novo; salvar a casa,
   marcar pago ou tirar o boleto nao avisam. Sem URL em `fin_config` ele
   fica quieto e o anexo funciona normal.
2. **n8n:** importe `n8n/boleto-whatsapp.json` (Workflows > Import from
   file). O no amarelo "Leia primeiro" diz as tres credenciais a criar:
   Header Auth do webhook (`x-segredo`), Supabase API (chave
   **service_role**, so no n8n) e Header Auth da Meta (`Authorization:
   Bearer <token permanente>`). No no **Configuracao** ficam o ID do numero
   do WhatsApp, o nome do modelo e os dias de validade do link do PDF.
3. **Meta:** modelo `boleto_anexado` (Utilidade, pt_BR, cabecalho Documento,
   4 variaveis: nome, casa, vencimento, valor). O texto esta no no "Leia
   primeiro". Espere a aprovacao.
4. **Ligar:** ative o fluxo, copie a URL de **producao** do no Webhook e
   grave na `fin_config` junto com o segredo (o insert esta comentado no
   comeco do `sql/003_aviso_n8n.sql`). Anexe um boleto numa casa com
   telefone e confira: WhatsApp do cliente, selo Enviado na parcela, e a
   execucao no n8n. Se nada chegou no n8n, `select * from
   net._http_response order by id desc limit 5` no SQL Editor mostra o que o
   banco recebeu de volta.

O fluxo nao reenvia sozinho: se a Meta recusar (numero sem WhatsApp, modelo
nao aprovado, token vencido), a execucao termina em "Nao enviado: ver o erro"
e a parcela fica sem o selo. Para mandar de novo, tire o PDF e anexe outra
vez.

### Lembrete no dia seguinte ao vencimento

Um segundo fluxo, `n8n/boleto-vencido.json`, roda todo dia as 9h (horario de
Fortaleza): busca as parcelas que venceram ontem e seguem sem pagamento, com
boleto anexado e casa com WhatsApp, manda o modelo `boleto_vencido` com o
mesmo PDF e grava `parcelas.lembrete_vencido_em` (`sql/004_lembrete_vencido.sql`);
a parcela ganha o selo **Cobrado**. Janela de seguranca: so parcelas vencidas
entre 1 e 7 dias, entao parcelas antigas nunca recebem cobranca em massa.
Parcela sem boleto anexado nao recebe lembrete (nao ha PDF para mandar).
Se a equipe marcou **Pago** antes das 9h, nao manda. Usa as mesmas tres
credenciais do primeiro fluxo. Para ver quem receberia hoje sem esperar as
9h: abra o no "Parcelas vencidas ontem" e clique em Execute step.

## Onde esta no codigo

Tudo em `index.html`. O banco em `sql/001_financeiro.sql`. A leitura da
planilha colada usa os mesmos nomes de cabecalho que o sincronizador da
Central (`apps-script/sincronizar.gs` la): as colunas sao achadas pelo nome,
nunca pela posicao.
