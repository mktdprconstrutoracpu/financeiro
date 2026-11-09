-- ============================================================================
-- Financeiro DPR - 003: o banco avisa o n8n quando um boleto e anexado
--
-- Quando parcelas.boleto_caminho muda para um PDF novo, um gatilho manda um
-- POST para o webhook do n8n (extensao pg_net, que ja vem no Supabase). O
-- n8n faz o resto: telefone do comprador, link do PDF, WhatsApp, e grava
-- parcelas.boleto_enviado_em (ver n8n/boleto-whatsapp.json).
--
-- O endereco do n8n e o segredo do webhook NAO ficam neste arquivo: ficam na
-- tabela fin_config, que so o banco le (RLS ligado sem politica + revoke).
-- Depois de rodar este arquivo, grave os dois valores com o passo 2 abaixo.
--
-- COMO RODAR
-- 1. Supabase > SQL Editor > New query > colar este arquivo inteiro > Run.
--    Pode rodar mais de uma vez. Precisa do 002 ja rodado.
-- 2. Numa query NOVA, com os SEUS valores (a URL de producao do webhook, que
--    aparece no no "Webhook" do fluxo importado, e um segredo qualquer, longo,
--    igual ao que voce colocar na credencial "Header Auth" do n8n):
--
--      insert into public.fin_config (chave, valor) values
--        ('n8n_boleto_url',     'https://SEU-N8N.app.n8n.cloud/webhook/boleto-anexado'),
--        ('n8n_boleto_segredo', 'UM-SEGREDO-LONGO-SO-SEU')
--      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
--
--    Sem a linha n8n_boleto_url o gatilho nao manda nada (e nao da erro: o
--    anexo no Financeiro continua funcionando).
-- ============================================================================

create extension if not exists pg_net with schema extensions;


-- ----------------------------------------------------------------------------
-- 1. fin_config - ajustes que nao podem ir para o repositorio
-- ----------------------------------------------------------------------------
create table if not exists public.fin_config (
  chave          text primary key,
  valor          text,
  atualizado_em  timestamptz not null default now()
);

comment on table public.fin_config is
  'Ajustes do Financeiro que ficam so no banco (URL e segredo do webhook do n8n). Ninguem le pelo navegador.';

alter table public.fin_config enable row level security;
revoke all on table public.fin_config from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. o gatilho: boleto novo -> POST no n8n
--
-- Manda o mesmo formato dos Database Webhooks do Supabase (type, table,
-- record, old_record), entao o fluxo do n8n le $json.body.record.*.
-- security definer para ler fin_config; pg_net e assincrono, o Financeiro
-- nao espera a resposta do n8n.
-- ----------------------------------------------------------------------------
create or replace function public.fin_boleto_para_n8n()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url     text;
  v_segredo text;
begin
  select valor into v_url     from public.fin_config where chave = 'n8n_boleto_url';
  select valor into v_segredo from public.fin_config where chave = 'n8n_boleto_segredo';
  if coalesce(v_url, '') = '' then
    return new;  -- n8n ainda nao configurado: segue a vida
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-segredo',    coalesce(v_segredo, '')),
    body    := jsonb_build_object(
                 'type',       'UPDATE',
                 'table',      'parcelas',
                 'schema',     'public',
                 'record',     to_jsonb(new),
                 'old_record', to_jsonb(old)),
    timeout_milliseconds := 5000
  );
  return new;
exception when others then
  -- um problema no aviso nunca pode impedir o anexo do boleto
  raise warning 'fin_boleto_para_n8n: %', sqlerrm;
  return new;
end;
$$;

revoke all on function public.fin_boleto_para_n8n() from public, anon, authenticated;

drop trigger if exists parcelas_boleto_para_n8n on public.parcelas;
create trigger parcelas_boleto_para_n8n
  after update of boleto_caminho on public.parcelas
  for each row
  when (new.boleto_caminho is not null
        and new.boleto_caminho is distinct from old.boleto_caminho)
  execute function public.fin_boleto_para_n8n();

comment on trigger parcelas_boleto_para_n8n on public.parcelas is
  'Boleto novo anexado no Financeiro -> POST no webhook do n8n (fin_config), que manda o PDF para o WhatsApp do comprador.';

-- Como conferir se o aviso saiu (SQL Editor):
--   select id, created, status_code, error_msg
--     from net._http_response order by id desc limit 5;
