-- Feature construction
{@aggregated} ? {
IF OBJECT_ID('tempdb..#raw_data', 'U') IS NOT NULL
	DROP TABLE #raw_data;

IF OBJECT_ID('tempdb..#overall_stats', 'U') IS NOT NULL
	DROP TABLE #overall_stats;

IF OBJECT_ID('tempdb..#prep_stats', 'U') IS NOT NULL
	DROP TABLE #prep_stats;

IF OBJECT_ID('tempdb..#prep_stats2', 'U') IS NOT NULL
	DROP TABLE #prep_stats2;

SELECT subject_id,
	cohort_start_date,
{@temporal} ? {
    time_id,
}	
{@sub_type == 'stratified'} ? {
	covariate_id,
}
	concept_count
INTO #raw_data
} : {
{@sub_type == 'stratified'} ? {
SELECT covariate_id,
} : {
SELECT CAST(1000 + @analysis_id AS BIGINT) AS covariate_id,
}
{@temporal} ? {
	time_id,
}	
	row_id,
	concept_count AS covariate_value
INTO @covariate_table	
}
FROM (
	SELECT 
{@temporal} ? {
		time_id,
}	
{@sub_type == 'stratified'} ? {
		CAST(@domain_concept_id AS BIGINT) * 1000 + @analysis_id AS covariate_id,
}
{@aggregated} ? {
		subject_id,
		cohort_start_date,
} : {
		cohort.@row_id_field AS row_id,
}
{@sub_type == 'distinct'} ? {
		COUNT(DISTINCT @domain_concept_id) AS concept_count
} : {
		COUNT(*) AS concept_count
}
	FROM @cohort_table cohort
	INNER JOIN @cdm_database_schema.@domain_table
		ON cohort.subject_id = @domain_table.person_id
{@temporal} ? {
	INNER JOIN #time_period time_period
		ON @domain_start_date <= DATEADD(DAY, time_period.end_day, cohort.cohort_start_date)
		AND @domain_end_date >= DATEADD(DAY, time_period.start_day, cohort.cohort_start_date)
	WHERE @domain_concept_id != 0
} : {
	WHERE @domain_start_date <= DATEADD(DAY, @end_day, cohort.cohort_start_date)
		AND @domain_end_date >= DATEADD(DAY, @start_day, cohort.cohort_start_date)
		AND @domain_concept_id != 0
}
{@excluded_concept_table != ''} ? {		AND @domain_concept_id NOT IN (SELECT id FROM @excluded_concept_table)}
{@included_concept_table != ''} ? {		AND @domain_concept_id IN (SELECT id FROM @included_concept_table)}
{@cohort_definition_id != -1} ? {		AND cohort.cohort_definition_id = @cohort_definition_id}
	GROUP BY 
{@temporal} ? {
		time_id,
}	
{@sub_type == 'stratified'} ? {
		@domain_concept_id,
} 
{@aggregated} ? {
		subject_id,
		cohort_start_date
} : {

		cohort.@row_id_field		
}	
	) raw_data;

{@aggregated} ? {
WITH t1 AS (
	SELECT COUNT(*) AS cnt 
	FROM @cohort_table 
{@cohort_definition_id != -1} ? {	WHERE cohort_definition_id = @cohort_definition_id}
	),
t2 AS (
	SELECT COUNT(*) AS cnt, 
{@sub_type == 'stratified'} ? {
		covariate_id,
} 
		MIN(concept_count) AS min_concept_count, 
		MAX(concept_count) AS max_concept_count, 
		SUM(CAST(concept_count AS BIGINT)) AS sum_concept_count,
		SUM(CAST(concept_count AS BIGINT) * CAST(concept_count AS BIGINT)) AS squared_concept_count
	FROM #raw_data
{@sub_type == 'stratified'} ? {
	GROUP BY covariate_id
} 
	)
SELECT CASE WHEN t2.cnt = t1.cnt THEN t2.min_concept_count ELSE 0 END AS min_value,
	t2.max_concept_count AS max_value,
{@sub_type == 'stratified'} ? {
	covariate_id,
} 
	CAST(t2.sum_concept_count / (1.0 * t1.cnt) AS FLOAT) AS average_value,
	CAST(CASE
		WHEN t2.cnt = 1 THEN 0 
		ELSE SQRT((1.0 * t2.cnt*t2.squared_concept_count - 1.0 * t2.sum_concept_count*t2.sum_concept_count) / (1.0 * t2.cnt*(1.0 * t2.cnt - 1))) 
	END AS FLOAT) AS standard_deviation,
	t2.cnt AS count_value,
	t1.cnt - t2.cnt AS count_no_value,
	t1.cnt AS population_size
INTO #overall_stats
FROM t1, t2;

SELECT concept_count,
	COUNT(*) AS total,
{@sub_type == 'stratified'} ? {
	covariate_id,
	ROW_NUMBER() OVER (PARTITION BY covariate_id ORDER BY concept_count) AS rn
} : {
	ROW_NUMBER() OVER (ORDER BY concept_count) AS rn
}
INTO #prep_stats
FROM #raw_data
GROUP BY concept_count
{@sub_type == 'stratified'} ? {
	,covariate_id
}
;
	
SELECT s.concept_count,
{@sub_type == 'stratified'} ? {
	s.covariate_id,
}
	SUM(p.total) AS accumulated
INTO #prep_stats2	
FROM #prep_stats s
INNER JOIN #prep_stats p
	ON p.rn <= s.rn
{@sub_type == 'stratified'} ? {
	AND p.covariate_id= s.covariate_id
}
GROUP BY s.concept_count
{@sub_type == 'stratified'} ? {
	,s.covariate_id
}
;

{@sub_type == 'stratified'} ? {
SELECT o.covariate_id,
} : {
SELECT CAST(1000 + @analysis_id AS BIGINT) AS covariate_id,
}
{@temporal} ? {
    CAST(NULL AS INT) AS time_id,
}
	o.count_value,
	o.min_value,
	o.max_value,
	CAST(o.average_value AS FLOAT) average_value,
	CAST(o.standard_deviation AS FLOAT) standard_deviation,
	CASE 
		WHEN .50 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .50 * o.population_size THEN concept_count	END) 
		END AS median_value,
	CASE 
		WHEN .10 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .10 * o.population_size THEN concept_count	END) 
		END AS p10_value,		
	CASE 
		WHEN .25 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .25 * o.population_size THEN concept_count	END) 
		END AS p25_value,	
	CASE 
		WHEN .75 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .75 * o.population_size THEN concept_count	END) 
		END AS p75_value,	
	CASE 
		WHEN .90 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .90 * o.population_size THEN concept_count	END) 
		END AS p90_value		
INTO @covariate_table
FROM #prep_stats2 p
{@sub_type == 'stratified'} ? {
INNER JOIN #overall_stats o
ON p.covariate_id = o.covariate_id
{@included_cov_table != ''} ? {WHERE covariate_id IN (SELECT id FROM @included_cov_table)}
} : {
CROSS JOIN #overall_stats o
{@included_cov_table != ''} ? {WHERE 1000 + @analysis_id IN (SELECT id FROM @included_cov_table)}
}
GROUP BY o.count_value,
	o.count_no_value,
	o.min_value,
	o.max_value,
	o.average_value,
	o.standard_deviation,
{@sub_type == 'stratified'} ? {
	o.covariate_id,
}
	o.population_size;
	
TRUNCATE TABLE #raw_data;
DROP TABLE #raw_data;

TRUNCATE TABLE #overall_stats;
DROP TABLE #overall_stats;

TRUNCATE TABLE #prep_stats;
DROP TABLE #prep_stats;

TRUNCATE TABLE #prep_stats2;
DROP TABLE #prep_stats2;	
} 

-- Reference construction
INSERT INTO #cov_ref (
	covariate_id,
	covariate_name,
	analysis_id,
	concept_id
	)
SELECT covariate_id,
{@temporal} ? {
{@sub_type == 'distinct'} ? {
	CAST('@domain_table distinct concept count' AS VARCHAR(512)) AS covariate_name,
} : { {@sub_type == 'stratified'} ? {
	CAST(CONCAT('@domain_table concept count: ', CASE WHEN concept_name IS NULL THEN 'Unknown concept' ELSE concept_name END) AS VARCHAR(512)) AS covariate_name,
} : {
	CAST('@domain_table concept count' AS VARCHAR(512)) AS covariate_name,
}
}
} : {
{@sub_type == 'distinct'} ? {
	CAST('@domain_table distinct concept count during day @start_day through @end_day concept_count relative to index' AS VARCHAR(512)) AS covariate_name,
} : { {@sub_type == 'stratified'} ? {
	CAST(CONCAT('@domain_table concept count during day @start_day through @end_day concept_count relative to index: ', CASE WHEN concept_name IS NULL THEN 'Unknown concept' ELSE concept_name END) AS VARCHAR(512)) AS covariate_name,
} : {
	CAST('@domain_table concept count during day @start_day through @end_day concept_count relative to index' AS VARCHAR(512)) AS covariate_name,
}
}
}
	@analysis_id AS analysis_id,
	0 AS concept_id
FROM (
	SELECT DISTINCT covariate_id
	FROM @covariate_table
	) t1
{@sub_type == 'stratified'} ? {
LEFT JOIN @cdm_database_schema.concept
	ON concept_id = CAST((covariate_id - @analysis_id) / 1000 AS INT)
}
;
	
INSERT INTO #analysis_ref (
	analysis_id,
	analysis_name,
	domain_id,
{!@temporal} ? {
	start_day,
	end_day,
}
	is_binary,
	missing_means_zero
	)
SELECT @analysis_id AS analysis_id,
	CAST('@analysis_name' AS VARCHAR(512)) AS analysis_name,
	CAST('@domain_id' AS VARCHAR(20)) AS domain_id,
{!@temporal} ? {
	CAST(NULL AS INT) AS start_day,
	CAST(NULL AS INT) AS end_day,
}
	CAST('N' AS VARCHAR(1)) AS is_binary,
	CAST('Y' AS VARCHAR(1)) AS missing_means_zero;
