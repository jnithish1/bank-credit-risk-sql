/* =============================================================================
   Q14 - Product holding matrix and customer income profile
   -----------------------------------------------------------------------------
   Business question
     How do customers combine products (card, loan, standing orders), and how
     do pension-income customers differ from salary-income customers? Reveals
     under-served groups - e.g. whether the bank lends to pensioners at all.
   Stakeholder: Product Management
   Techniques: CUBE (every combination + subtotals + grand total in one pass),
               GROUPING() to label subtotal rows, window share-of-total
   ============================================================================= */

WITH acct AS (
    SELECT a.account_id,
           CASE WHEN a.has_card THEN 'card' ELSE 'no card' END            AS card,
           CASE WHEN a.has_loan THEN 'loan' ELSE 'no loan' END            AS loan,
           CASE WHEN EXISTS (SELECT 1 FROM mart.fact_account_month m
                             WHERE m.account_id = a.account_id AND m.pension_inflow > 0)
                THEN 'pension income' ELSE 'other income' END              AS income_type,
           b.month_end_balance
    FROM mart.dim_account a
    JOIN mart.fact_account_month b
      ON b.account_id = a.account_id
     AND b.month_start = date_trunc('month', mart.fn_as_of_date())
)
SELECT CASE WHEN GROUPING(income_type) = 1 THEN 'ALL' ELSE income_type END AS income_type,
       CASE WHEN GROUPING(card)        = 1 THEN 'ALL' ELSE card        END AS card,
       CASE WHEN GROUPING(loan)        = 1 THEN 'ALL' ELSE loan        END AS loan,
       count(*)                                                           AS accounts,
       round(100.0 * count(*) / (SELECT count(*) FROM acct), 1)           AS pct_of_all_accounts,
       round(avg(month_end_balance))                                      AS avg_balance_czk
FROM acct
GROUP BY CUBE (income_type, card, loan)
ORDER BY GROUPING(income_type), income_type, GROUPING(card), card, GROUPING(loan), loan;
