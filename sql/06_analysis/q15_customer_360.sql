/* =============================================================================
   Q15 - Customer 360 view for relationship managers / collections
   -----------------------------------------------------------------------------
   Business question
     When a collections agent opens a case for a borrower who is in arrears,
     what single view of the customer do they need on screen?
   Stakeholder: Collections / Relationship Management (operational use)
   Techniques: set-returning SQL function (mart.fn_customer_360) invoked per
               row with CROSS JOIN LATERAL; function internally uses a LATERAL
               subquery over the monthly fact
   Demo: the 5 borrowers currently running in debt with the largest loans.
   ============================================================================= */

SELECT c360.*
FROM (
    SELECT owner_client_id
    FROM mart.fact_loan
    WHERE status_code = 'D'
    ORDER BY amount DESC
    LIMIT 5
) cases
CROSS JOIN LATERAL mart.fn_customer_360(cases.owner_client_id) AS c360
WHERE c360.role = 'OWNER';
