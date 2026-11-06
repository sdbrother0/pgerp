-- =====================================================================
-- Пакет решения «CRM», выпуск 2: цвета меток — в данных
-- =====================================================================
--  * crm_stages.tone — цвет метки стадии (neutral, accent, attention, success, done, danger);
--    стадии демо-данных получают прежние цвета. Цвет новой стадии задаётся строкой справочника.
--  * Колонки «Стадия» и «Состояние» отдают {label, tone} через pgerp.ui_badge (помощник ядра);
--    crm_badge больше не нужна.
-- Выпуск применяется один раз: на базе, где он уже записан (pgerp.solution_releases), он пропускается.
SELECT pgerp.solution_release_apply('crm', 2, 'Badge colors in data', $release$
-- ---------------------------------------------------------------------
-- Цвет стадии — в справочнике стадий (тон метки, см. pgerp.ui_badge)
-- ---------------------------------------------------------------------
ALTER TABLE crm_stages ADD COLUMN IF NOT EXISTS tone VARCHAR(20) NOT NULL DEFAULT 'neutral'
    CHECK (tone IN ('neutral', 'accent', 'attention', 'success', 'done', 'danger'));
COMMENT ON COLUMN crm_stages.tone IS 'Stage badge color: neutral, accent, attention, success, done, danger';

UPDATE crm_stages SET tone = CASE code
        WHEN 'new'         THEN 'accent'
        WHEN 'qualified'   THEN 'attention'
        WHEN 'proposal'    THEN 'done'
        WHEN 'negotiation' THEN 'done'
        WHEN 'won'         THEN 'success'
        WHEN 'lost'        THEN 'danger'
        ELSE tone END
WHERE tone = 'neutral';

-- ---------------------------------------------------------------------
-- Представления: метка — {label, tone}; тон стадии — из справочника, тон задачи — по её состоянию
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW crm_deals_v AS
SELECT d.id, d.title, d.company_id, co.name AS company, d.contact_id, ct.full_name AS contact,
       d.stage_id, s.code AS stage_code, s.sort_order AS stage_order, ui_badge(s.name, s.tone) AS stage,
       s.probability, s.is_closed, s.is_won,
       d.owner_login, crm_user_name(d.owner_login) AS owner,
       COALESCE(a.amount, 0) AS amount,
       round(COALESCE(a.amount, 0) * s.probability / 100, 2) AS weighted,
       d.expected_close, crm_date(d.expected_close) AS close_date,
       (NOT s.is_closed AND d.expected_close < current_date) AS is_overdue,
       d.closed_on, d.lost_reason, d.created_at,
       lower(concat_ws(' ', d.title, co.name)) AS search_text
FROM crm_deals d
JOIN crm_companies co ON co.id = d.company_id
JOIN crm_stages s ON s.id = d.stage_id
LEFT JOIN crm_contacts ct ON ct.id = d.contact_id
LEFT JOIN (SELECT deal_id, sum(amount) AS amount FROM crm_deal_lines_v GROUP BY deal_id) a ON a.deal_id = d.id
WHERE crm_can_see(d.owner_login);

CREATE OR REPLACE VIEW crm_activities_v AS
SELECT a.id, a.kind, ui_t(k.name) AS kind_name, a.subject, a.notes,
       a.due_on, crm_date(a.due_on) AS due, COALESCE(a.due_on, DATE '9999-12-31') AS due_sort,
       x.state_code, ui_badge(x.state_name, x.state_tone) AS state,
       a.done_at IS NOT NULL AS is_done, a.done_at,
       a.deal_id, d.title AS deal,
       COALESCE(a.company_id, d.company_id) AS company_id, co.name AS company,
       COALESCE(d.title, co.name) AS related,
       a.owner_login, crm_user_name(a.owner_login) AS owner,
       lower(concat_ws(' ', a.subject, d.title, co.name)) AS search_text
FROM crm_activities a
JOIN crm_activity_kinds k ON k.code = a.kind
LEFT JOIN crm_deals d ON d.id = a.deal_id
LEFT JOIN crm_companies co ON co.id = COALESCE(a.company_id, d.company_id)
CROSS JOIN LATERAL (
    SELECT CASE WHEN a.done_at IS NOT NULL THEN 'done'
                WHEN a.due_on < current_date THEN 'overdue'
                WHEN a.due_on = current_date THEN 'today'
                ELSE 'open' END AS state_code,
           CASE WHEN a.done_at IS NOT NULL THEN 'Completed'
                WHEN a.due_on < current_date THEN 'Overdue'
                WHEN a.due_on = current_date THEN 'Today'
                ELSE 'Planned' END AS state_name,
           CASE WHEN a.done_at IS NOT NULL THEN 'success'
                WHEN a.due_on < current_date THEN 'danger'
                WHEN a.due_on = current_date THEN 'attention'
                ELSE 'neutral' END AS state_tone) x
WHERE crm_can_see(a.owner_login);

CREATE OR REPLACE VIEW crm_pipeline_v AS
SELECT s.id, s.sort_order, ui_badge(s.name, s.tone) AS stage, ui_t(s.name) AS stage_name, s.probability,
       count(d.id) AS deals, COALESCE(sum(d.amount), 0) AS amount, COALESCE(sum(d.weighted), 0) AS weighted
FROM crm_stages s
LEFT JOIN crm_deals_v d ON d.stage_id = s.id
GROUP BY s.id;

DROP FUNCTION IF EXISTS crm_badge(TEXT, TEXT);
$release$);
