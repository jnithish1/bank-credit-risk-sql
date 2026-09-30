# Connection defaults match docker-compose.yml; override on the command line.
export PGHOST     ?= localhost
export PGPORT     ?= 5432
export PGUSER     ?= postgres
export PGPASSWORD ?= postgres
export PGDATABASE ?= berka

.PHONY: all db pipeline sample analysis charts clean

all: pipeline analysis charts        ## full build: warehouse + results + charts

db:                                   ## start PostgreSQL in Docker
	docker compose up -d --wait

pipeline:                             ## load raw CSVs -> staging -> core -> DQ gate -> mart
	./scripts/run_pipeline.sh raw

sample:                               ## same pipeline on the 10% sample (what CI runs)
	./scripts/run_pipeline.sh sample

analysis:                             ## run the 15 business queries -> results/*.csv
	./scripts/run_analysis.sh

charts:                               ## render README charts from results/
	python3 scripts/make_charts.py

clean:                                ## drop the warehouse schemas
	psql -c "DROP SCHEMA IF EXISTS mart, core, staging, audit CASCADE;"
