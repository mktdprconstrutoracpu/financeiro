-- ============================================================================
-- Financeiro DPR - 002: o boleto vai para o WhatsApp do cliente
--
-- Quando a equipe anexa o boleto de uma parcela no Financeiro, o n8n manda o
-- PDF para o WhatsApp do comprador (API oficial da Meta). Este arquivo so
-- ACRESCENTA duas colunas as tabelas da Central:
--
--   unidades.telefone           o WhatsApp do comprador, so numeros, com o
--                               DDI (ex.: 5585999998888). Preenchido na ficha
--                               da casa, no Financeiro.
--   parcelas.boleto_enviado_em  a hora em que o n8n mandou o boleto. Nulo =
--                               ainda nao mandou. O Financeiro mostra "Enviado"
--                               ao lado do PDF quando esta preenchido.
--
-- O aviso do banco para o n8n (Database Webhook) fica no 003, porque leva a
-- URL do seu n8n e um segredo: nao pode ficar gravado no repositorio.
--
-- COMO RODAR
-- Supabase > SQL Editor > New query > colar este arquivo inteiro > Run.
-- Pode rodar mais de uma vez ("if not exists"). Precisa do 001 ja rodado.
-- ============================================================================

alter table public.unidades
  add column if not exists telefone text;

comment on column public.unidades.telefone is
  'WhatsApp do comprador, so numeros com DDI (5585999998888). Para onde o n8n manda o boleto assim que ele e anexado no Financeiro.';

alter table public.parcelas
  add column if not exists boleto_enviado_em timestamptz;

comment on column public.parcelas.boleto_enviado_em is
  'Quando o n8n mandou o boleto desta parcela pelo WhatsApp. Nulo = ainda nao mandou.';

-- As travas ja existentes cobrem as colunas novas: a equipe do Financeiro le e
-- escreve (unidades_financeiro, parcelas_financeiro); o cliente le so a propria
-- casa (unidades_le_a_propria), e o telefone que aparece para ele e o dele.
