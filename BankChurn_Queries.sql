/* ============================================================================================
   ANALYTICAL CRM DEVELOPMENT FOR A BANK  —  SQL SOLUTION FILE
   Project : Bank Customer Churn Analysis (Capstone)   |   Dialect : MySQL 8.0   |   DB : bank_crm
   Load the 7 CSVs in /SQL_Import_CSVs/ into tables of the same name, then run top-to-bottom.
   ============================================================================================ */
USE bank_crm;

SET SQL_SAFE_UPDATES = 0;

/* Rename HasCrCard -> Has_creditcard (idempotent). */
SET @needs_rename := (SELECT COUNT(*) FROM information_schema.COLUMNS
                      WHERE TABLE_SCHEMA = DATABASE()
                        AND TABLE_NAME   = 'Bank_Churn'
                        AND COLUMN_NAME  = 'HasCrCard');
SET @rename_sql := IF(@needs_rename > 0,
                      'ALTER TABLE Bank_Churn RENAME COLUMN HasCrCard TO Has_creditcard',
                      'DO 0');
PREPARE stmt FROM @rename_sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

/* PERFORMANCE | Supporting indexes on join keys and common filter columns (idempotent). */
DROP PROCEDURE IF EXISTS add_index_if_missing;
DELIMITER //
CREATE PROCEDURE add_index_if_missing(IN tbl VARCHAR(64), IN idx VARCHAR(64), IN cols VARCHAR(255))
BEGIN
    IF (SELECT COUNT(*) FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = tbl AND INDEX_NAME = idx) = 0 THEN
        SET @ddl := CONCAT('CREATE INDEX ', idx, ' ON ', tbl, ' (', cols, ')');
        PREPARE s FROM @ddl; EXECUTE s; DEALLOCATE PREPARE s;
    END IF;
END //
DELIMITER ;

-- Join keys (used by nearly every analytical query)
CALL add_index_if_missing('Bank_Churn',   'ix_bc_customer', 'CustomerId');
CALL add_index_if_missing('CustomerInfo', 'ix_ci_customer', 'CustomerId');
CALL add_index_if_missing('CustomerInfo', 'ix_ci_geo',      'GeographyID');
CALL add_index_if_missing('CustomerInfo', 'ix_ci_gender',   'GenderID');
-- Common filter / group-by columns on the fact table
CALL add_index_if_missing('Bank_Churn',   'ix_bc_exited',   'Exited');
CALL add_index_if_missing('Bank_Churn',   'ix_bc_active_tenure', 'IsActiveMember, Tenure');
CALL add_index_if_missing('Bank_Churn',   'ix_bc_card',     'Has_creditcard');

DROP PROCEDURE IF EXISTS add_index_if_missing;

/* ============================================================================================
                                   OBJECTIVE QUESTIONS
   ============================================================================================ */

/* Q1 | What is the distribution of account balances across different regions? */
SELECT  g.GeographyLocation,
        COUNT(*)                       AS Customers,
        ROUND(SUM(b.Balance), 2)       AS TotalBalance,
        ROUND(AVG(b.Balance), 2)       AS AvgBalance,
        ROUND(MIN(b.Balance), 2)       AS MinBalance,
        ROUND(MAX(b.Balance), 2)       AS MaxBalance
FROM        Bank_Churn   b
JOIN        CustomerInfo c ON b.CustomerId = c.CustomerId
JOIN        Geography    g ON c.GeographyID = g.GeographyID
GROUP BY    g.GeographyLocation
ORDER BY    AvgBalance DESC;


/* Q2 | Top 5 customers with the highest Estimated Salary in the last quarter (Oct–Dec) of the year. (SQL) */
SELECT   c.CustomerId,
         c.Surname,
         c.EstimatedSalary,
         c.`Bank DOJ`
FROM     CustomerInfo c
WHERE    MONTH(c.`Bank DOJ`) IN (10, 11, 12)      -- Q4 = October, November, December
ORDER BY c.EstimatedSalary DESC
LIMIT    5;



/* Q3 | Average number of products used by customers who have a credit card. (SQL) */
SELECT   ROUND(AVG(NumOfProducts), 4) AS AvgProducts_CreditCardHolders
FROM     Bank_Churn
WHERE    Has_creditcard = 1;


/* Q4 | Churn rate by gender for the MOST RECENT year in the dataset. */
SELECT   gn.GenderCategory,
         COUNT(*)                                   AS Customers,
         SUM(b.Exited)                              AS Churned,
         ROUND(100.0 * SUM(b.Exited) / COUNT(*), 2) AS ChurnRatePct
FROM     Bank_Churn   b
JOIN     CustomerInfo c  ON b.CustomerId = c.CustomerId
JOIN     Gender       gn ON c.GenderID   = gn.GenderID
WHERE    YEAR(c.`Bank DOJ`) = (SELECT MAX(YEAR(`Bank DOJ`)) FROM CustomerInfo)   -- most recent year
GROUP BY gn.GenderCategory
ORDER BY ChurnRatePct DESC;


/* Q5 | Compare the average credit score of customers who have exited vs. those who remain. (SQL) */
SELECT   CASE WHEN Exited = 1 THEN 'Exited' ELSE 'Retained' END AS CustomerStatus,
         COUNT(*)                    AS Customers,
         ROUND(AVG(CreditScore), 2)  AS AvgCreditScore
FROM     Bank_Churn
GROUP BY Exited
ORDER BY Exited DESC;


/* Q6 | Which gender has a higher average estimated salary, and how does it relate to active accounts? (SQL) */
SELECT   gn.GenderCategory,
         ROUND(AVG(c.EstimatedSalary), 2)             AS AvgEstimatedSalary,
         SUM(b.IsActiveMember)                        AS ActiveAccounts,
         COUNT(*)                                     AS TotalCustomers,
         ROUND(100.0*SUM(b.IsActiveMember)/COUNT(*),2) AS ActivePct
FROM     CustomerInfo c
JOIN     Gender     gn ON c.GenderID   = gn.GenderID
JOIN     Bank_Churn b  ON b.CustomerId = c.CustomerId
GROUP BY gn.GenderCategory
ORDER BY AvgEstimatedSalary DESC;


/* Q7 | Segment customers by credit score; identify the segment with the highest exit rate. (SQL) */
SELECT   CreditSegment,
         COUNT(*)                                   AS Customers,
         SUM(Exited)                                AS Churned,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)   AS ExitRatePct
FROM (
    SELECT Exited,
           CASE WHEN CreditScore >= 800 THEN 'Excellent (800-850)'
                WHEN CreditScore >= 740 THEN 'Very Good (740-799)'
                WHEN CreditScore >= 670 THEN 'Good (670-739)'
                WHEN CreditScore >= 580 THEN 'Fair (580-669)'
                ELSE                          'Poor (300-579)' END AS CreditSegment
    FROM   Bank_Churn
) seg
GROUP BY CreditSegment
ORDER BY ExitRatePct DESC;


/* Q8 | Geographic region with the highest number of active customers with tenure > 5 years. (SQL) */
SELECT   g.GeographyLocation,
         COUNT(*) AS ActiveCustomers_TenureOver5
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId  = c.CustomerId
JOIN     Geography    g ON c.GeographyID = g.GeographyID
WHERE    b.IsActiveMember = 1
  AND    b.Tenure > 5
GROUP BY g.GeographyLocation
ORDER BY ActiveCustomers_TenureOver5 DESC;


/* Q9 | Impact of having a credit card on customer churn. */
SELECT   CASE WHEN Has_creditcard = 1 THEN 'Has Credit Card' ELSE 'No Credit Card' END AS CardStatus,
         COUNT(*)                                   AS Customers,
         SUM(Exited)                                AS Churned,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)   AS ChurnRatePct
FROM     Bank_Churn
GROUP BY Has_creditcard
ORDER BY ChurnRatePct DESC;


/* Q10 | For customers who have exited, the most common number of products used. */
SELECT   NumOfProducts,
         COUNT(*) AS ExitedCustomers
FROM     Bank_Churn
WHERE    Exited = 1
GROUP BY NumOfProducts
ORDER BY ExitedCustomers DESC;


/* Q11 | Trend of customers joining over time + seasonal patterns (yearly & monthly). (SQL) */
-- (a) Yearly trend
SELECT   YEAR(`Bank DOJ`) AS JoinYear,
         COUNT(*)         AS NewCustomers
FROM     CustomerInfo
GROUP BY YEAR(`Bank DOJ`)
ORDER BY JoinYear;

-- (b) Monthly seasonality (aggregated across all years)
SELECT   MONTH(`Bank DOJ`)     AS MonthNo,
         MONTHNAME(`Bank DOJ`)  AS MonthName,
         COUNT(*)              AS NewCustomers
FROM     CustomerInfo
GROUP BY MONTH(`Bank DOJ`), MONTHNAME(`Bank DOJ`)
ORDER BY MonthNo;

-- (c) Year-Month time series (for the Power BI line chart)
SELECT   DATE_FORMAT(`Bank DOJ`, '%Y-%m') AS YearMonth,
         COUNT(*)                         AS NewCustomers
FROM     CustomerInfo
GROUP BY DATE_FORMAT(`Bank DOJ`, '%Y-%m')
ORDER BY YearMonth;


/* Q12 | Relationship between number of products and account balance for customers who have exited. */
SELECT   NumOfProducts,
         COUNT(*)                 AS ExitedCustomers,
         ROUND(AVG(Balance), 2)   AS AvgBalance,
         ROUND(MIN(Balance), 2)   AS MinBalance,
         ROUND(MAX(Balance), 2)   AS MaxBalance
FROM     Bank_Churn
WHERE    Exited = 1
GROUP BY NumOfProducts
ORDER BY NumOfProducts;


/* Q13 | Potential outliers in balance among RETAINED customers.
         Two standard approaches shown: (a) 3-sigma (z-score) and (b) IQR (Tukey's fences). */
-- (a) 3-sigma rule
SELECT   b.CustomerId, b.Balance
FROM     Bank_Churn b
CROSS JOIN (SELECT AVG(Balance) AS mu, STDDEV_POP(Balance) AS sd
            FROM Bank_Churn WHERE Exited = 0) s
WHERE    b.Exited = 0
  AND    ABS(b.Balance - s.mu) > 3 * s.sd
ORDER BY b.Balance DESC;

-- (b) IQR method (MySQL 8 window percentiles via NTILE)
WITH q AS (
    SELECT Balance,
           NTILE(4) OVER (ORDER BY Balance) AS quartile
    FROM   Bank_Churn WHERE Exited = 0
),
bounds AS (
    SELECT MAX(CASE WHEN quartile = 1 THEN Balance END) AS Q1,
           MAX(CASE WHEN quartile = 3 THEN Balance END) AS Q3
    FROM   q
)
SELECT   bc.CustomerId, bc.Balance
FROM     Bank_Churn bc, bounds
WHERE    bc.Exited = 0
  AND   (bc.Balance < Q1 - 1.5*(Q3 - Q1) OR bc.Balance > Q3 + 1.5*(Q3 - Q1))
ORDER BY bc.Balance DESC;


/* Q14 | How many tables are in the dataset, and which consist ONLY of categorical variables?
   Answer: 7 tables were supplied. Two are FACT tables at customer grain (Bank_Churn, CustomerInfo);
   the other FIVE - Geography, Gender, CreditCard, ActiveCustomer, ExitCustomer - are LOOKUP tables
   that hold only categorical values (an ID paired with its label). The query lists every table and
   its column count as evidence. */
SELECT   t.TABLE_NAME,
         COUNT(c.COLUMN_NAME) AS ColumnCount
FROM     information_schema.TABLES  t
JOIN     information_schema.COLUMNS c
         ON c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
WHERE    t.TABLE_SCHEMA = 'bank_crm'
GROUP BY t.TABLE_NAME
ORDER BY ColumnCount, t.TABLE_NAME;


/* Q15 | Gender-wise average income in each geography id; rank the gender by average value. (SQL) */
SELECT   c.GeographyID,
         g.GeographyLocation,
         gn.GenderCategory,
         ROUND(AVG(c.EstimatedSalary), 2)                                              AS AvgIncome,
         RANK() OVER (PARTITION BY c.GeographyID ORDER BY AVG(c.EstimatedSalary) DESC)  AS GenderRank
FROM     CustomerInfo c
JOIN     Gender    gn ON c.GenderID    = gn.GenderID
JOIN     Geography g  ON c.GeographyID = g.GeographyID
GROUP BY c.GeographyID, g.GeographyLocation, gn.GenderCategory
ORDER BY c.GeographyID, GenderRank;


/* Q16 | Average tenure of people who have exited, in each age bracket (18-30, 30-50, 50+). (SQL) */
SELECT   CASE WHEN c.Age <= 30 THEN '18-30'
              WHEN c.Age <= 50 THEN '30-50'
              ELSE                  '50+'  END AS AgeBracket,
         COUNT(*)               AS ExitedCustomers,
         ROUND(AVG(b.Tenure),2) AS AvgTenure
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId = c.CustomerId
WHERE    b.Exited = 1
GROUP BY AgeBracket
ORDER BY AgeBracket;


/* Q17 | Correlation between salary and balance — overall and split by exited/retained.
         Pearson r computed with the raw formula (MySQL has no CORR()). */
SELECT   'Overall' AS Segment,
         ROUND( (COUNT(*)*SUM(c.EstimatedSalary*b.Balance) - SUM(c.EstimatedSalary)*SUM(b.Balance)) /
                ( SQRT(COUNT(*)*SUM(POW(c.EstimatedSalary,2)) - POW(SUM(c.EstimatedSalary),2)) *
                  SQRT(COUNT(*)*SUM(POW(b.Balance,2))         - POW(SUM(b.Balance),2)) ), 4) AS PearsonR
FROM     Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId
UNION ALL
SELECT   CASE WHEN b.Exited = 1 THEN 'Exited' ELSE 'Retained' END,
         ROUND( (COUNT(*)*SUM(c.EstimatedSalary*b.Balance) - SUM(c.EstimatedSalary)*SUM(b.Balance)) /
                ( SQRT(COUNT(*)*SUM(POW(c.EstimatedSalary,2)) - POW(SUM(c.EstimatedSalary),2)) *
                  SQRT(COUNT(*)*SUM(POW(b.Balance,2))         - POW(SUM(b.Balance),2)) ), 4)
FROM     Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId
GROUP BY b.Exited;


/* Q18 | Correlation between salary and credit score. */
SELECT   ROUND( (COUNT(*)*SUM(c.EstimatedSalary*b.CreditScore) - SUM(c.EstimatedSalary)*SUM(b.CreditScore)) /
                ( SQRT(COUNT(*)*SUM(POW(c.EstimatedSalary,2)) - POW(SUM(c.EstimatedSalary),2)) *
                  SQRT(COUNT(*)*SUM(POW(b.CreditScore,2))      - POW(SUM(b.CreditScore),2)) ), 4) AS PearsonR_Salary_CreditScore
FROM     Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId;


/* Q19 | Rank each credit-score bucket by the number of customers who churned. (SQL) */
SELECT   CreditSegment,
         COUNT(*)                              AS ChurnedCustomers,
         RANK() OVER (ORDER BY COUNT(*) DESC)  AS ChurnRank
FROM (
    SELECT CASE WHEN CreditScore >= 800 THEN 'Excellent (800-850)'
                WHEN CreditScore >= 740 THEN 'Very Good (740-799)'
                WHEN CreditScore >= 670 THEN 'Good (670-739)'
                WHEN CreditScore >= 580 THEN 'Fair (580-669)'
                ELSE                          'Poor (300-579)' END AS CreditSegment
    FROM   Bank_Churn
    WHERE  Exited = 1
) t
GROUP BY CreditSegment
ORDER BY ChurnRank;


/* Q20 | Per age bucket: number of customers with a credit card; return buckets below the average. (SQL) */
WITH cc_per_bucket AS (
    SELECT CASE WHEN c.Age <= 30 THEN '18-30'
                WHEN c.Age <= 50 THEN '30-50'
                ELSE                  '50+'  END AS AgeBracket,
           SUM(b.Has_creditcard) AS CreditCardHolders
    FROM   Bank_Churn   b
    JOIN   CustomerInfo c ON b.CustomerId = c.CustomerId
    GROUP  BY AgeBracket
)
SELECT   AgeBracket, CreditCardHolders,
         (SELECT ROUND(AVG(CreditCardHolders),2) FROM cc_per_bucket) AS AvgPerBucket
FROM     cc_per_bucket
WHERE    CreditCardHolders < (SELECT AVG(CreditCardHolders) FROM cc_per_bucket)
ORDER BY CreditCardHolders;


/* Q21 | Rank the locations by number of churned customers and by average balance. (SQL) */
SELECT   g.GeographyLocation,
         SUM(b.Exited)                                  AS ChurnedCustomers,
         ROUND(AVG(b.Balance), 2)                       AS AvgBalance,
         RANK() OVER (ORDER BY SUM(b.Exited)  DESC)     AS ChurnRank,
         RANK() OVER (ORDER BY AVG(b.Balance) DESC)     AS AvgBalanceRank
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId  = c.CustomerId
JOIN     Geography    g ON c.GeographyID = g.GeographyID
GROUP BY g.GeographyLocation
ORDER BY ChurnRank;


/* Q22 | Create a "CustomerID_Surname" composite key in the format CustomerID_Surname. (SQL) */
-- Idempotent: add the column only if it does not already exist (safe to re-run).
SET @needs_col := (SELECT COUNT(*) = 0 FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE()
                     AND TABLE_NAME   = 'CustomerInfo'
                     AND COLUMN_NAME  = 'CustomerID_Surname');
SET @add_col_sql := IF(@needs_col,
                       'ALTER TABLE CustomerInfo ADD COLUMN CustomerID_Surname VARCHAR(120)',
                       'DO 0');
PREPARE stmt FROM @add_col_sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
UPDATE CustomerInfo
SET    CustomerID_Surname = CONCAT(CustomerId, '_', Surname);


/* Q23 | Get "ExitCategory" from ExitCustomer into Bank_Churn WITHOUT using JOIN. (SQL) */
-- Option A: CASE expression (no join, no extra table)
SELECT   CustomerId,
         Exited,
         CASE WHEN Exited = 1 THEN 'Exit' ELSE 'Retain' END AS ExitCategory
FROM     Bank_Churn;

-- Option B: correlated scalar sub-query against ExitCustomer (still no JOIN keyword)
SELECT   b.CustomerId,
         b.Exited,
         (SELECT e.ExitCategory FROM ExitCustomer e WHERE e.ExitID = b.Exited) AS ExitCategory
FROM     Bank_Churn b;


/* Q24 | Detect missing values (handling / tool is discussed in the doc; here is the SQL detection). */
SELECT  SUM(CreditScore    IS NULL) AS Null_CreditScore,
        SUM(Tenure         IS NULL) AS Null_Tenure,
        SUM(Balance        IS NULL) AS Null_Balance,
        SUM(NumOfProducts  IS NULL) AS Null_NumOfProducts,
        SUM(Has_creditcard IS NULL) AS Null_HasCrCard,
        SUM(IsActiveMember IS NULL) AS Null_IsActiveMember,
        SUM(Exited         IS NULL) AS Null_Exited
FROM    Bank_Churn;


/* Q25 | Customer IDs, last name, and active status for customers whose surname ends with "on". (SQL) */
SELECT   c.CustomerId,
         c.Surname AS LastName,
         CASE WHEN b.IsActiveMember = 1 THEN 'Active' ELSE 'Inactive' END AS ActiveStatus
FROM     CustomerInfo c
JOIN     Bank_Churn   b ON c.CustomerId = b.CustomerId
WHERE    c.Surname LIKE '%on'
ORDER BY c.Surname;


/* Q26 | Data discrepancy between IsActiveMember and Exited (Exited is accurate).
         A customer who has EXITED cannot still be an ACTIVE member. */
-- (a) Identify the discrepancy
SELECT   COUNT(*) AS Discrepancy_Exited_And_Active
FROM     Bank_Churn
WHERE    Exited = 1 AND IsActiveMember = 1;

-- (b) Full contradiction matrix
SELECT   Exited, IsActiveMember, COUNT(*) AS Customers
FROM     Bank_Churn
GROUP BY Exited, IsActiveMember
ORDER BY Exited, IsActiveMember;


/* ============================================================================================
                      SUBJECTIVE QUESTIONS  —  SUPPORTING SQL
   These back the tables / charts used in the report's subjective answers. Run BEFORE the final
   cleaning step so IsActiveMember still holds the RECORDED value (as used in the report).
   ============================================================================================ */

/* S1 | Customer behaviour — long-term (tenure 6-7 yrs) vs newer (tenure 3-4 yrs). */
SELECT   segment                                       AS CustomerGroup,
         COUNT(*)                                       AS Customers,
         ROUND(AVG(Balance), 2)                         AS AvgBalance,
         ROUND(AVG(NumOfProducts), 2)                   AS AvgProducts,
         ROUND(100.0 * SUM(IsActiveMember) / COUNT(*), 1) AS ActivePct,
         ROUND(100.0 * SUM(Exited)         / COUNT(*), 1) AS ChurnRatePct
FROM (
    SELECT *,
           CASE WHEN Tenure >= 6 THEN 'Long-term (6-7 yrs)'
                WHEN Tenure <= 4 THEN 'Newer (3-4 yrs)' END AS segment
    FROM   Bank_Churn
) t
WHERE    segment IS NOT NULL
GROUP BY segment
ORDER BY segment DESC;


/* S2 | Product affinity — churn by number of products (two products is the sweet spot). */
SELECT   NumOfProducts,
         COUNT(*)                                   AS Customers,
         SUM(Exited)                                AS Churned,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)   AS ChurnRatePct
FROM     Bank_Churn
GROUP BY NumOfProducts
ORDER BY NumOfProducts;


/* S3 | Geographic market trends — average balance and churn rate by region. */
SELECT   g.GeographyLocation,
         COUNT(*)                                       AS Customers,
         ROUND(AVG(b.Balance), 2)                       AS AvgBalance,
         ROUND(100.0 * SUM(b.Exited) / COUNT(*), 2)     AS ChurnRatePct
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId  = c.CustomerId
JOIN     Geography    g ON c.GeographyID = g.GeographyID
GROUP BY g.GeographyLocation
ORDER BY AvgBalance DESC;


/* S4 | Risk management — highest-risk segments ranked by balance at stake. */
SELECT   '3-4 products' AS Segment,
         COUNT(*)                                           AS Customers,
         ROUND(AVG(Balance), 2)                             AS AvgBalance,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)           AS ChurnRatePct,
         ROUND(SUM(CASE WHEN Exited = 1 THEN Balance ELSE 0 END), 2) AS BalanceHeldByLeavers
FROM     Bank_Churn
WHERE    NumOfProducts >= 3
UNION ALL
SELECT   '50+ & inactive',
         COUNT(*),
         ROUND(AVG(b.Balance), 2),
         ROUND(100.0 * SUM(b.Exited) / COUNT(*), 2),
         ROUND(SUM(CASE WHEN b.Exited = 1 THEN b.Balance ELSE 0 END), 2)
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId = c.CustomerId
WHERE    c.Age > 50 AND b.IsActiveMember = 0
UNION ALL
SELECT   'Germany',
         COUNT(*),
         ROUND(AVG(b.Balance), 2),
         ROUND(100.0 * SUM(b.Exited) / COUNT(*), 2),
         ROUND(SUM(CASE WHEN b.Exited = 1 THEN b.Balance ELSE 0 END), 2)
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId  = c.CustomerId
JOIN     Geography    g ON c.GeographyID = g.GeographyID
WHERE    g.GeographyLocation = 'Germany';


/* S7 | Common characteristics of leavers — churn rate per trait vs the overall average. */
WITH base AS (
    SELECT ROUND(100.0 * SUM(Exited) / COUNT(*), 2) AS OverallChurnPct FROM Bank_Churn
)
SELECT   seg.Characteristic,
         seg.ChurnRatePct,
         ROUND(seg.ChurnRatePct - base.OverallChurnPct, 1) AS VsAveragePt
FROM     base,
(
    SELECT 'Age 50+' AS Characteristic, ROUND(100.0*SUM(b.Exited)/COUNT(*),2) AS ChurnRatePct
      FROM Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId WHERE c.Age > 50
    UNION ALL
    SELECT '3-4 products', ROUND(100.0*SUM(Exited)/COUNT(*),2) FROM Bank_Churn WHERE NumOfProducts >= 3
    UNION ALL
    SELECT 'Germany', ROUND(100.0*SUM(b.Exited)/COUNT(*),2)
      FROM Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId
      JOIN Geography g ON c.GeographyID = g.GeographyID WHERE g.GeographyLocation = 'Germany'
    UNION ALL
    SELECT 'Inactive', ROUND(100.0*SUM(Exited)/COUNT(*),2) FROM Bank_Churn WHERE IsActiveMember = 0
    UNION ALL
    SELECT '1 product', ROUND(100.0*SUM(Exited)/COUNT(*),2) FROM Bank_Churn WHERE NumOfProducts = 1
    UNION ALL
    SELECT 'Female', ROUND(100.0*SUM(b.Exited)/COUNT(*),2)
      FROM Bank_Churn b JOIN CustomerInfo c ON b.CustomerId = c.CustomerId
      JOIN Gender gn ON c.GenderID = gn.GenderID WHERE gn.GenderCategory = 'Female'
) seg
ORDER BY seg.ChurnRatePct DESC;


/* S8 | Predictive value of the candidate features (evidence for the assessment table).
   Products = S2 above; salary correlation = Q17/Q18 above; activity + tenure shown here. */
-- (a) Activity signal — inactive churn roughly double active
SELECT   CASE WHEN IsActiveMember = 1 THEN 'Active' ELSE 'Inactive' END AS ActivityStatus,
         COUNT(*)                                   AS Customers,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)   AS ChurnRatePct
FROM     Bank_Churn
GROUP BY IsActiveMember
ORDER BY IsActiveMember;

-- (b) Tenure signal — churn is flat across the 3-7 year range (weak predictor)
SELECT   Tenure,
         COUNT(*)                                   AS Customers,
         ROUND(100.0 * SUM(Exited) / COUNT(*), 2)   AS ChurnRatePct
FROM     Bank_Churn
GROUP BY Tenure
ORDER BY Tenure;


/* S9 | Customer segmentation by demographics & account details (Subjective question 9). */
SELECT   g.GeographyLocation,
         gn.GenderCategory,
         CASE WHEN c.Age <= 30 THEN '18-30' WHEN c.Age <= 50 THEN '30-50' ELSE '50+' END AS AgeBracket,
         CASE WHEN b.IsActiveMember = 1 THEN 'Active' ELSE 'Inactive' END                AS Activity,
         COUNT(*)                                    AS Customers,
         ROUND(AVG(b.Balance),2)                     AS AvgBalance,
         ROUND(AVG(c.EstimatedSalary),2)             AS AvgSalary,
         ROUND(100.0*SUM(b.Exited)/COUNT(*),2)       AS ChurnRatePct
FROM     Bank_Churn   b
JOIN     CustomerInfo c  ON b.CustomerId  = c.CustomerId
JOIN     Geography    g  ON c.GeographyID = g.GeographyID
JOIN     Gender       gn ON c.GenderID    = gn.GenderID
GROUP BY g.GeographyLocation, gn.GenderCategory, AgeBracket, Activity
ORDER BY ChurnRatePct DESC;


/* S11 | Churn rate per cohort (join) year — overall churn is a steady one-in-five. */
SELECT   YEAR(c.`Bank DOJ`)                            AS JoinYear,
         COUNT(*)                                       AS Customers,
         SUM(b.Exited)                                  AS Churned,
         ROUND(100.0 * SUM(b.Exited) / COUNT(*), 2)     AS ChurnRatePct
FROM     Bank_Churn   b
JOIN     CustomerInfo c ON b.CustomerId = c.CustomerId
GROUP BY YEAR(c.`Bank DOJ`)
ORDER BY JoinYear;


/* ============================================================================================
   FINAL CLEANING STEP | Apply the Q26 correction (run LAST, after all analysis above).
   Exited is the source of truth, so an exited customer cannot be an active member.
   ============================================================================================ */
UPDATE  Bank_Churn
SET     IsActiveMember = 0
WHERE   Exited = 1 AND IsActiveMember = 1;

/* ===============================  END OF SQL SOLUTION FILE  ================================= */
