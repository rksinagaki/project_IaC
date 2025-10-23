import sys
import json
from datetime import datetime

import boto3

from awsglue.transforms import *
from awsgluedq.transforms import EvaluateDataQuality
from awsglue.dynamicframe import DynamicFrame
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, when, to_date, regexp_replace, trim, lit, sum
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, LongType, TimestampType, BooleanType
from pyspark.sql.window import Window

## @params: [JOB_NAME]
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    's3_input_path_channel', # 動的
    's3_input_path_video', # 動的
    's3_input_path_comment', # 動的
    'processed_base_path', # 動的
    'report_base_path', # 動的
    'artist_name_slug', # 動的
    'correlation_id',

    'crawler_name',# 静的
    'gcp_project_id',
    # 'bq_dataset',
    # 'bq_table'
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)
spark.sparkContext.setLogLevel("ERROR") 
spark_logger = glueContext.get_logger()

# ////////////
# 環境変数呼び出し
# ////////////
JOB_NAME = args['JOB_NAME']
S3_INPUT_PATH_CHANNEL = args['s3_input_path_channel']
S3_INPUT_PATH_VIDEO = args['s3_input_path_video']
S3_INPUT_PATH_COMMENT = args['s3_input_path_comment']
PROCESSED_BASE_PATH = args['processed_base_path']
REPORT_BASE_PATH = args['report_base_path']
ARTIST_NAME_SLUG = args['artist_name_slug']

CORRELATION_ID = args['correlation_id']
GCP_PROJECT_ID = args['gcp_project_id']
BQ_DATASET = args['bq_dataset']

# ////////////
# ロガー関数
# ////////////
def log_json(message, level="INFO", extra={}):
    log_data = {
        "timestamp": datetime.now().isoformat(),
        "log_level": level,
        "service": JOB_NAME,
        "correlation_id": CORRELATION_ID,
        "message": message,
    }
    log_data.update(extra) 
    
    print(json.dumps(log_data))

# ////////////
# DQの関数
# ////////////
def run_data_quality_check(df, glueContext, df_name, result_s3_prefix):
    dyf_to_check = DynamicFrame.fromDF(df, glueContext, df_name)
    
    if df_name == "channel":
        dqdl_ruleset = """
        Rules = [
            IsComplete "channel_id",
            IsUnique "channel_id",
            Completeness "published_at" >= 0.90
        ]
        """
        
    elif df_name == "video":
        dqdl_ruleset = """
        Rules = [
            IsComplete "video_id",
            IsUnique "video_id",
            Completeness "total_seconds" >= 0.90,
            Completeness "published_at" >= 0.90
        ]
        """
        
    elif df_name == "comment":
        dqdl_ruleset = """
        Rules = [
            IsComplete "comment_id",
            IsUnique "comment_id",
            Completeness "published_at" >= 0.90
        ]
        """

    dq_results = EvaluateDataQuality.apply(
        frame=dyf_to_check,
        ruleset=dqdl_ruleset,
        publishing_options={
            "dataQualityEvaluationContext": df_name,
            "enableDataQualityResultsPublishing": True,
            "resultsS3Prefix": result_s3_prefix
        }
    )
    dq_df = dq_results.toDF()
    
    return dq_df

# ////////////
# スキーマ設計
# ////////////
# channelデータのスキーマ設計
channel_schema = StructType([
    StructField("channel_id", StringType(), False),
    StructField("channel_name", StringType(), False),
    StructField("published_at", StringType(), False),# 後で処理
    StructField("subscriber_count", LongType(), False),
    StructField("total_views", LongType(), False),
    StructField("video_count", LongType(), False)
])

# videoデータのスキーマ設計
video_schema = StructType([
    StructField("video_id", StringType(), False),
    StructField("title", StringType(), False),
    StructField("published_at", StringType(), False),
    StructField("view_count", LongType(), False),
    StructField("like_count", LongType(), False),
    StructField("comment_count", LongType(), False),
    StructField("duration", StringType(), False),
    StructField("tags", StringType(), False)
])

# commentデータのスキーマ設計
comment_schema = StructType([
    StructField("video_id", StringType(), False),
    StructField("comment_id", StringType(), False),
    StructField("author_display_name", StringType(), False),
    StructField("published_at", StringType(), False),
    StructField("text_display", StringType(), False),
    StructField("like_count", LongType(), False)
])

# ////////////
# データの読み込み
# ////////////
log_json("GlueJobを開始しました。S3からデータの読み込みを開始しました。")

df_channel = spark.read.schema(channel_schema).json(S3_INPUT_PATH_CHANNEL)
df_video = spark.read.schema(video_schema).json(S3_INPUT_PATH_VIDEO)
df_comment = spark.read.schema(comment_schema).json(S3_INPUT_PATH_COMMENT)

spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("S3からデータの読み込みが完了しました。")

# ////////////
# データ型変換
# ////////////
spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("データ型の変換を開始しました。")

# channelデータ型変更
df_channel = df_channel.withColumn(
    'published_at',
    F.col('published_at').cast('timestamp')
)

# videoデータ型変更
df_video = df_video.withColumn(
    'published_at',
    F.col('published_at').cast('timestamp')
)

# durationを秒数に変換
df_video = df_video.withColumn(
    "total_seconds",
    (
        F.coalesce(F.regexp_extract(F.col("duration"), "(\d+)H", 1).cast(LongType()), F.lit(0)) * 3600
    ) + (
        F.coalesce(F.regexp_extract(F.col("duration"), "(\d+)M", 1).cast(LongType()), F.lit(0)) * 60
    ) + (
        F.coalesce(F.regexp_extract(F.col("duration"), "(\d+)S", 1).cast(LongType()), F.lit(0))
    )
)

# commentデータ型変更
df_comment = df_comment.withColumn(
    'published_at',
    F.col('published_at').cast('timestamp')
)

spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("データ型の変換が完了しました。")

# ////////////
# 欠損、重複値処理(必ず欠損→重複の順番で処理を行う)
# ////////////
spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("欠損値、重複値の処理を開始しました。")

# 欠損値の処理
df_channel = df_channel.filter(F.col('channel_id').isNotNull())

df_video = df_video.filter(
    F.col('video_id').isNotNull() & 
    F.col('published_at').isNotNull()
)

df_comment = df_comment.filter(
    F.col('comment_id').isNotNull() &
    F.col('published_at').isNotNull()
)

# 重複値の処理
window_channel = Window.partitionBy('channel_id').orderBy(F.col('published_at').desc())
df_channel_ranked = df_channel.withColumn('rank', F.row_number().over(window_channel))
df_channel = df_channel_ranked.filter(F.col('rank') == 1).drop('rank')

window_video = Window.partitionBy('video_id').orderBy(F.col('published_at').desc())
df_video_ranked = df_video.withColumn('rank', F.row_number().over(window_video))
df_video = df_video_ranked.filter(F.col('rank') == 1).drop('rank')

window_comment = Window.partitionBy('comment_id').orderBy(F.col('published_at').desc())
df_comment_ranked = df_comment.withColumn('rank', F.row_number().over(window_comment))
df_comment = df_comment_ranked.filter(F.col('rank')==1).drop('rank')

spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("欠損値、重複値の処理が完了しました。")

# ////////////
# DataQualityの実行
# ////////////
spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("データクオリティーの実施を開始しました。S3へレポートの出力を行います。")

run_data_quality_check(
    df_channel,
    glueContext,
    "channel",
    f"s3://{REPORT_BASE_PATH}channel/"
    )
    
run_data_quality_check(
    df_video,
    glueContext,
    "video",
    f"s3://{REPORT_BASE_PATH}video/"
    )

run_data_quality_check(
    df_comment,
    glueContext,
    "comment",
    f"s3://{REPORT_BASE_PATH}comment/"
    )

spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("データクオリティーの実施が完了しました。S3へレポートを出力しました。")
    
# ////////////
# データの格納
# ////////////
spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("S3へデータの格納を開始しました。")

df_channel.write.mode("overwrite").parquet(f"s3://{PROCESSED_BASE_PATH}processed_channel")
df_video.write.mode("overwrite").parquet(f"s3://{PROCESSED_BASE_PATH}processed_video")
df_comment.write.mode("overwrite").parquet(f"s3://{PROCESSED_BASE_PATH}processed_comment")

spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
log_json("S3へデータの格納が完了しました。")

# ////////////
# BigQueryへデータの格納
# ////////////
# BQへチャンネルデータの格納
dynamic_channel = DynamicFrame.fromDF(df_channel, glueContext, "converted_frame")

glueContext.write_dynamic_frame.from_options(
    frame=dynamic_channel,
    connection_type="bigquery",
    connection_options={
        "connectionName": "bigquery-connector-spark-connection",
        "parentProject": GCP_PROJECT_ID,
        "writeMethod": "direct",
        "table": f"{BQ_DATASET}.{ARTIST_NAME_SLUG}_channel"
    }
)
# BQへビデオデータの格納
dynamic_video = DynamicFrame.fromDF(df_video, glueContext, "converted_frame")

glueContext.write_dynamic_frame.from_options(
    frame=dynamic_video,
    connection_type="bigquery",
    connection_options={
        "connectionName": "bigquery-connector-spark-connection",
        "parentProject": GCP_PROJECT_ID,
        "writeMethod": "direct",
        "table": f"{BQ_DATASET}.{ARTIST_NAME_SLUG}_video"
    }
)

# BQへコメントデータの格納
dynamic_comment = DynamicFrame.fromDF(df_comment, glueContext, "converted_frame")

glueContext.write_dynamic_frame.from_options(
    frame=dynamic_comment,
    connection_type="bigquery",
    connection_options={
        "connectionName": "bigquery-connector-spark-connection",
        "parentProject": GCP_PROJECT_ID,
        "writeMethod": "direct",
        "table": f"{BQ_DATASET}.{ARTIST_NAME_SLUG}_comment"
    }
)

# ////////////
# データカタログの更新
# ////////////
# spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
# log_json("データカタログの更新を開しました。")

# try:
#     glue_client = boto3.client('glue')
#     print(f"Attempting to start crawler: {CRAWLER_NAME}")

#     glue_client.start_crawler(Name=CRAWLER_NAME)
#     print("Crawler started successfully to update Data Catalog.")

# except Exception as e:
#     print(f"Warning: Error starting crawler {CRAWLER_NAME}: {e}")

# spark_logger.info("--- Spark Action completed. Flushing log buffer. ---")
# log_json("データカタログの更新を完了しました。GlueJobを完了しました。")
    
job.commit()