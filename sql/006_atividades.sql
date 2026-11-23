-- ============================================================================
-- 006_atividades.sql  (23/11/2026)
--
-- Notificacoes do Financeiro: quem da equipe criou, alterou ou excluiu o que.
--   fin_atividades   uma linha por mudanca feita por alguem logado (casa, ficha,
--                    parcela, boleto). Quem grava e o proprio banco (gatilhos), entao
--                    nada escapa e ninguem forja aviso.
--   fin_leituras     ate quando cada pessoa ja viu os avisos (vale em qualquer aparelho)
-- So entram mudancas feitas por alguem logado: a sincronizacao da planilha e os fluxos
-- do n8n usam a chave de servico (sem usuario) e nao geram aviso.
-- Quem ve: quem tem acesso ao Financeiro (fin_tem_acesso, do sql/001).
-- Rode no SQL Editor do Supabase. Pode rodar de novo.
-- ============================================================================

create table if not exists public.fin_atividades (
  id              bigint generated always as identity primary key,
  criado_em       timestamptz not null default now(),
  user_id         uuid,
  email           text,
  nome            text,
  unidade_id      bigint,
  unidade         text,
  empreendimento  text,
  tipo            text not null,
  detalhe         text
);
create index if not exists fin_atividades_criado_idx on public.fin_atividades (criado_em desc);

create table if not exists public.fin_leituras (
  user_id    uuid primary key default auth.uid(),
  visto_ate  timestamptz not null default now()
);

-- quem esta mexendo (null = chave de servico: planilha, n8n -> nao registra)
create or replace function public.fin_quem()
returns table (uid uuid, email text, nome text)
language sql stable security definer set search_path = public as $$
  select auth.uid(),
         lower(coalesce(auth.jwt() ->> 'email', '')),
         coalesce(
           (select nullif(trim(l.nome), '') from public.fin_liberacoes l where lower(l.email) = lower(coalesce(auth.jwt() ->> 'email', '')) limit 1),
           initcap(translate(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), '._-', '   '))
         )
$$;

create or replace function public.fin_situacao_nome(s text)
returns text language sql immutable as $$
  select case s when 'ativo' then 'Ativo' when 'aguardando_assinatura' then 'Aguardando assinatura'
                when 'distrato_aguardando' then 'Distrato (aguardando)' when 'distrato_realizado' then 'Distrato realizado'
                when 'permuta' then 'Permuta' else coalesce(s, '') end
$$;

-- casas: nova, excluida, ficha alterada (com o que mudou)
create or replace function public.fin_atividade_unidade()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  q record;
  mudou text[] := '{}';
  linha public.unidades%rowtype;
begin
  select * into q from public.fin_quem();
  if q.uid is null then return null; end if;
  linha := case when tg_op = 'DELETE' then old else new end;
  if tg_op = 'INSERT' then
    insert into public.fin_atividades (user_id, email, nome, unidade_id, unidade, empreendimento, tipo, detalhe)
    values (q.uid, q.email, q.nome, new.id, new.unidade, new.empreendimento, 'casa_nova', nullif(trim(coalesce(new.comprador, '')), ''));
  elsif tg_op = 'DELETE' then
    insert into public.fin_atividades (user_id, email, nome, unidade_id, unidade, empreendimento, tipo, detalhe)
    values (q.uid, q.email, q.nome, old.id, old.unidade, old.empreendimento, 'casa_excluida', nullif(trim(coalesce(old.comprador, '')), ''));
  else
    if new.status_contrato is distinct from old.status_contrato then
      insert into public.fin_atividades (user_id, email, nome, unidade_id, unidade, empreendimento, tipo, detalhe)
      values (q.uid, q.email, q.nome, new.id, new.unidade, new.empreendimento, 'situacao',
              public.fin_situacao_nome(old.status_contrato) || ' -> ' || public.fin_situacao_nome(new.status_contrato));
    end if;
    if new.comprador is distinct from old.comprador then mudou := array_append(mudou, 'comprador'::text); end if;
    if new.unidade is distinct from old.unidade or new.empreendimento is distinct from old.empreendimento then mudou := array_append(mudou, 'unidade'::text); end if;
    if new.valor_venda is distinct from old.valor_venda then mudou := array_append(mudou, 'valor da venda'::text); end if;
    if new.saldo_devedor_atual is distinct from old.saldo_devedor_atual then mudou := array_append(mudou, 'saldo devedor'::text); end if;
    if new.data_assinatura is distinct from old.data_assinatura then mudou := array_append(mudou, 'data de assinatura'::text); end if;
    if new.financiamento_proposto is distinct from old.financiamento_proposto or new.fgts_proposto is distinct from old.fgts_proposto then mudou := array_append(mudou, 'financiamento/FGTS'::text); end if;
    if new.telefone is distinct from old.telefone then mudou := array_append(mudou, 'WhatsApp'::text); end if;
    if to_jsonb(new) ->> 'email_comprador' is distinct from to_jsonb(old) ->> 'email_comprador'
       or to_jsonb(new) ->> 'email_conjuge' is distinct from to_jsonb(old) ->> 'email_conjuge' then mudou := array_append(mudou, 'e-mail'::text); end if;
    if to_jsonb(new) ->> 'cpf_comprador' is distinct from to_jsonb(old) ->> 'cpf_comprador'
       or to_jsonb(new) ->> 'cpf_conjuge' is distinct from to_jsonb(old) ->> 'cpf_conjuge' then mudou := array_append(mudou, 'CPF'::text); end if;
    if array_length(mudou, 1) > 0 then
      insert into public.fin_atividades (user_id, email, nome, unidade_id, unidade, empreendimento, tipo, detalhe)
      values (q.uid, q.email, q.nome, new.id, new.unidade, new.empreendimento, 'ficha', array_to_string(mudou, ', '));
    end if;
  end if;
  return null;
end $$;

-- parcelas: nova, excluida, paga/desmarcada, boleto anexado/retirado, valores alterados
create or replace function public.fin_atividade_parcela()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  q record;
  u record;
  p public.parcelas%rowtype;
  rotulo text;
  ins text := 'insert into public.fin_atividades (user_id, email, nome, unidade_id, unidade, empreendimento, tipo, detalhe) values ($1, $2, $3, $4, $5, $6, $7, $8)';
begin
  select * into q from public.fin_quem();
  if q.uid is null then return null; end if;
  p := case when tg_op = 'DELETE' then old else new end;
  -- casa excluida (as parcelas saem junto, em cascata): o aviso da casa basta
  select id, unidade, empreendimento into u from public.unidades where id = p.unidade_id;
  if not found then return null; end if;
  rotulo := 'parcela ' || coalesce(p.ordem::text, '?');
  if tg_op = 'INSERT' then
    execute ins using q.uid, q.email, q.nome, u.id, u.unidade, u.empreendimento, 'parcela_nova', rotulo;
  elsif tg_op = 'DELETE' then
    execute ins using q.uid, q.email, q.nome, u.id, u.unidade, u.empreendimento, 'parcela_excluida', rotulo;
  else
    if new.pago is distinct from old.pago then
      execute ins using q.uid, q.email, q.nome, u.id, u.unidade, u.empreendimento, case when new.pago then 'parcela_paga' else 'parcela_desmarcada' end, rotulo;
    end if;
    if new.boleto_caminho is distinct from old.boleto_caminho then
      execute ins using q.uid, q.email, q.nome, u.id, u.unidade, u.empreendimento, case when new.boleto_caminho is null then 'boleto_retirado' else 'boleto_anexado' end, rotulo;
    end if;
    if new.data_vencimento is distinct from old.data_vencimento or new.tipo_parcela is distinct from old.tipo_parcela
       or new.parcela_construtora is distinct from old.parcela_construtora or new.parcela_corrigida is distinct from old.parcela_corrigida
       or new.saldo_construtora is distinct from old.saldo_construtora or new.saldo_corrigido is distinct from old.saldo_corrigido
       or new.incc_percentual is distinct from old.incc_percentual or new.incc_valor is distinct from old.incc_valor
       or new.igpm_valor is distinct from old.igpm_valor or new.amortizacao is distinct from old.amortizacao or new.comissao is distinct from old.comissao then
      execute ins using q.uid, q.email, q.nome, u.id, u.unidade, u.empreendimento, 'parcela_alterada', rotulo;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists fin_atividade_unidade on public.unidades;
create trigger fin_atividade_unidade after insert or update or delete on public.unidades
  for each row execute function public.fin_atividade_unidade();
drop trigger if exists fin_atividade_parcela on public.parcelas;
create trigger fin_atividade_parcela after insert or update or delete on public.parcelas
  for each row execute function public.fin_atividade_parcela();

alter table public.fin_atividades enable row level security;
alter table public.fin_leituras enable row level security;
drop policy if exists fin_atividades_le on public.fin_atividades;
create policy fin_atividades_le on public.fin_atividades for select to authenticated using (public.fin_tem_acesso());
drop policy if exists fin_leituras_suas on public.fin_leituras;
create policy fin_leituras_suas on public.fin_leituras for all to authenticated
  using (user_id = auth.uid() and public.fin_tem_acesso()) with check (user_id = auth.uid() and public.fin_tem_acesso());
revoke all on public.fin_atividades from anon, authenticated;
revoke all on public.fin_leituras from anon, authenticated;
grant select on public.fin_atividades to authenticated;
grant select, insert, update on public.fin_leituras to authenticated;
revoke all on function public.fin_quem() from public, anon, authenticated;
revoke all on function public.fin_atividade_unidade() from public, anon, authenticated;
revoke all on function public.fin_atividade_parcela() from public, anon, authenticated;

-- aviso na hora (Realtime do Supabase): a tabela entra na publicacao, se ainda nao estiver
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'fin_atividades') then
    alter publication supabase_realtime add table public.fin_atividades;
  end if;
end $$;
