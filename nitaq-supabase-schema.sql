-- ============================================================
-- نظام نطاق ERP — مخطط قاعدة البيانات السحابية (Supabase)
-- شغّل هذا الملف مرة واحدة: Supabase Dashboard → SQL Editor → New Query → الصق → Run
-- ============================================================

-- 1) جدول الملفات الشخصية والأدوار
create table if not exists public.nitaq_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text,
  role text not null default 'engineer' check (role in ('owner','accountant','engineer')),
  created_at timestamptz default now()
);

-- أول مستخدم يسجل يصبح مالكاً تلقائياً، ومن بعده الافتراضي "مهندس" حتى يرقّيه المالك
create or replace function public.nitaq_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.nitaq_profiles (user_id, email, name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    case when (select count(*) from public.nitaq_profiles) = 0 then 'owner' else 'engineer' end
  );
  return new;
end; $$;

drop trigger if exists nitaq_on_auth_user_created on auth.users;
create trigger nitaq_on_auth_user_created
  after insert on auth.users
  for each row execute function public.nitaq_handle_new_user();

-- 2) جدول السجلات الموحد (كل كيانات النظام)
create table if not exists public.nitaq_records (
  id text primary key,
  entity text not null,
  data jsonb not null,
  updated_at timestamptz default now(),
  updated_by uuid references auth.users(id)
);
create index if not exists nitaq_records_entity_idx on public.nitaq_records(entity);

-- لتمكين البث اللحظي من إرسال بيانات الصف المحذوف
alter table public.nitaq_records replica identity full;

create or replace function public.nitaq_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end; $$;
drop trigger if exists nitaq_records_touch on public.nitaq_records;
create trigger nitaq_records_touch before insert or update on public.nitaq_records
  for each row execute function public.nitaq_touch();

-- 3) دالة مساعدة: دور المستخدم الحالي
create or replace function public.nitaq_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.nitaq_profiles where user_id = auth.uid();
$$;

-- 4) تفعيل أمان مستوى الصفوف (RLS)
alter table public.nitaq_profiles enable row level security;
alter table public.nitaq_records enable row level security;

-- الملفات الشخصية: الجميع يقرأ الأسماء، المالك فقط يعدل الأدوار
drop policy if exists nitaq_profiles_select on public.nitaq_profiles;
create policy nitaq_profiles_select on public.nitaq_profiles
  for select using (auth.uid() is not null);

drop policy if exists nitaq_profiles_update on public.nitaq_profiles;
create policy nitaq_profiles_update on public.nitaq_profiles
  for update using (public.nitaq_role() = 'owner');

-- السجلات: صلاحيات حسب الدور
-- المهندس: المشاريع، العقود، القرارات، الرسوم الحكومية، السيارات، الموظفون (للأسماء)
-- المحاسب والمالك: كل شيء
drop policy if exists nitaq_records_select on public.nitaq_records;
create policy nitaq_records_select on public.nitaq_records
  for select using (
    public.nitaq_role() in ('owner','accountant')
    or (public.nitaq_role() = 'engineer'
        and entity in ('projects','contracts','decisions','govFees','cars','employees'))
  );

drop policy if exists nitaq_records_insert on public.nitaq_records;
create policy nitaq_records_insert on public.nitaq_records
  for insert with check (
    public.nitaq_role() in ('owner','accountant')
    or (public.nitaq_role() = 'engineer'
        and entity in ('projects','contracts','decisions','govFees'))
  );

drop policy if exists nitaq_records_update on public.nitaq_records;
create policy nitaq_records_update on public.nitaq_records
  for update using (
    public.nitaq_role() in ('owner','accountant')
    or (public.nitaq_role() = 'engineer'
        and entity in ('projects','contracts','decisions','govFees'))
  );

-- الحذف: المالك يحذف كل شيء؛ المحاسب يحذف السجلات المالية فقط (ليس المشاريع/العقود)؛ المهندس يحذف القرارات فقط
drop policy if exists nitaq_records_delete on public.nitaq_records;
create policy nitaq_records_delete on public.nitaq_records
  for delete using (
    public.nitaq_role() = 'owner'
    or (public.nitaq_role() = 'accountant'
        and entity in ('payments','govFees','officeExpenses','projectCosts','treasury','overtime','advances','decisions'))
    or (public.nitaq_role() = 'engineer' and entity = 'decisions')
  );

-- 5) تفعيل البث اللحظي (Realtime)
do $$
begin
  alter publication supabase_realtime add table public.nitaq_records;
exception when duplicate_object then null;
end $$;

-- تم. ✅
-- الخطوة التالية: من الواجهة سجّل أول مستخدم (سيصبح المالك تلقائياً)،
-- ثم رقِّ باقي المستخدمين من شاشة "المستخدمون والصلاحيات" داخل النظام.
