-- PDS Diary schema v2 / Supabase PostgreSQL
create extension if not exists pgcrypto;

create table if not exists categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text default '🎀',
  color text default '#ff4fa0',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists plans (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text default '',
  category_id uuid references categories(id) on delete set null,
  start_date date not null,
  end_date date not null,
  priority text not null check(priority in ('low','medium','high')),
  success_mode text not null default 'preset' check(success_mode in ('preset','custom')),
  success_threshold numeric not null check(success_threshold between 0 and 100),
  estimated_minutes integer not null default 0 check(estimated_minutes >= 0),
  carry_improvement_enabled boolean not null default true,
  carried_improvement text default '',
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists plan_revisions (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  revision_no integer not null,
  title text not null,
  description text default '',
  category_id uuid,
  start_date date not null,
  end_date date not null,
  priority text not null,
  success_mode text not null,
  success_threshold numeric not null,
  estimated_minutes integer not null,
  saved_at timestamptz not null default now(),
  change_note text default '',
  unique(plan_id, revision_no)
);

create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  title text not null,
  description text default '',
  category_id uuid references categories(id) on delete set null,
  due_date date,
  priority text not null check(priority in ('low','medium','high')),
  tags text[] not null default '{}',
  estimated_minutes integer not null default 0 check(estimated_minutes >= 0),
  status text not null default 'todo' check(status in ('todo','done')),
  completed_at timestamptz,
  completion_cycle integer not null default 0,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists execution_records (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  actual_minutes integer not null check(actual_minutes >= 0),
  blocked_reason text default '',
  note text default '',
  created_at timestamptz not null default now(),
  check(ended_at >= started_at)
);

create table if not exists completion_events (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  completion_cycle integer not null,
  idempotency_key text not null,
  completed_at timestamptz not null default now(),
  unique(task_id, completion_cycle),
  unique(idempotency_key)
);

create table if not exists reviews (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  task_count integer not null default 0,
  completed_count integer not null default 0,
  overdue_count integer not null default 0,
  blocked_count integer not null default 0,
  estimated_minutes integer not null default 0,
  actual_minutes integer not null default 0,
  difference_minutes integer not null default 0,
  success_rate numeric not null default 0,
  success_threshold numeric not null default 0,
  is_success boolean not null default false,
  improvement text default '',
  carry_to_next_plan boolean not null default true,
  created_at_seoul timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists security_checks (
  id uuid primary key default gen_random_uuid(),
  test_text text not null,
  created_at timestamptz not null default now()
);

create or replace function snapshot_plan_revision() returns trigger language plpgsql as $$
declare next_no integer;
begin
  if row(old.title,old.description,old.category_id,old.start_date,old.end_date,old.priority,old.success_mode,old.success_threshold,old.estimated_minutes)
     is distinct from
     row(new.title,new.description,new.category_id,new.start_date,new.end_date,new.priority,new.success_mode,new.success_threshold,new.estimated_minutes) then
    select coalesce(max(revision_no),0)+1 into next_no from plan_revisions where plan_id=old.id;
    insert into plan_revisions(plan_id,revision_no,title,description,category_id,start_date,end_date,priority,success_mode,success_threshold,estimated_minutes,saved_at)
    values(old.id,next_no,old.title,old.description,old.category_id,old.start_date,old.end_date,old.priority,old.success_mode,old.success_threshold,old.estimated_minutes,now());
  end if;
  new.updated_at=now();
  return new;
end $$;

drop trigger if exists trg_plan_revision on plans;
create trigger trg_plan_revision before update on plans for each row execute function snapshot_plan_revision();

create or replace function complete_task(p_task_id uuid, p_idempotency_key text)
returns jsonb language plpgsql as $$
declare t tasks%rowtype;
begin
  select * into t from tasks where id=p_task_id for update;
  if t.id is null then raise exception 'task not found'; end if;
  if t.status='done' then return jsonb_build_object('changed',false,'reason','already_done'); end if;
  update tasks set status='done', completed_at=now(), updated_at=now() where id=p_task_id;
  insert into completion_events(plan_id,task_id,completion_cycle,idempotency_key,completed_at)
  values(t.plan_id,t.id,t.completion_cycle,p_idempotency_key,now())
  on conflict(task_id,completion_cycle) do nothing;
  return jsonb_build_object('changed',true);
end $$;

create or replace function reopen_task(p_task_id uuid)
returns jsonb language plpgsql as $$
declare t tasks%rowtype;
begin
  select * into t from tasks where id=p_task_id for update;
  if t.id is null then raise exception 'task not found'; end if;
  if t.status='todo' then return jsonb_build_object('changed',false,'reason','already_todo'); end if;
  update tasks set status='todo', completed_at=null, completion_cycle=completion_cycle+1, updated_at=now() where id=p_task_id;
  return jsonb_build_object('changed',true);
end $$;

-- 과제 6은 로그인 없이 공개되는 앱이므로 anon/public CRUD를 허용합니다.
-- 이 정책 때문에 링크를 아는 사람은 데이터를 볼 수 있고 수정도 할 수 있습니다.
alter table categories enable row level security;
alter table plans enable row level security;
alter table plan_revisions enable row level security;
alter table tasks enable row level security;
alter table execution_records enable row level security;
alter table completion_events enable row level security;
alter table reviews enable row level security;
alter table security_checks enable row level security;

do $$ declare t text; begin
  foreach t in array array['categories','plans','plan_revisions','tasks','execution_records','completion_events','reviews','security_checks'] loop
    execute format('drop policy if exists public_all on %I',t);
    execute format('create policy public_all on %I for all to anon, authenticated using (true) with check (true)',t);
  end loop;
end $$;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant execute on function complete_task(uuid,text) to anon, authenticated;
grant execute on function reopen_task(uuid) to anon, authenticated;
