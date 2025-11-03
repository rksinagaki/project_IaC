import os
import boto3
import json
import logging
from urllib.parse import urlparse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def delete_s3_prefix(bucket_name, prefix):
    s3 = boto3.resource('s3')
    bucket = s3.Bucket(bucket_name)
    
    # プレフィックスの末尾にスラッシュがない場合に追加
    if not prefix.endswith('/'):
        prefix += '/'

    logger.info(f"Deleting s3 objects from: s3://{bucket_name}/{prefix}")
    
    # オブジェクトのリストを取得し、一括で削除
    bucket.objects.filter(Prefix=prefix).delete()
    logger.info("S3 deletion complete.")

def delete_glue_table(database_name, table_name):
    glue = boto3.client('glue')
    logger.info(f"Deleting Glue table: {database_name}.{table_name}")
    try:
        glue.delete_table(
            DatabaseName=database_name,
            Name=table_name
        )
        logger.info("Glue table deleted successfully.")
    except glue.exceptions.EntityNotFoundException:
        logger.warning(f"Glue table not found (may have been deleted): {table_name}")
    except Exception as e:
        logger.error(f"Error deleting Glue table: {e}")

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    
    # 失敗の原因となったエラー詳細をログ出力 (Optional)
    error_details = event.get('ErrorDetails', {})
    if error_details:
        logger.error(f"Pipeline failed due to: {error_details.get('Error')} - {error_details.get('Cause')}")

    # 1. SFN入力から必要な情報を抽出
    # SFNのPayloadは実行状態全体（$.decoded_payloadなどを含む）
    decoded_payload = event.get('decoded_payload', {})
    
    # SFNから渡される値を使って、削除対象のS3パスを特定
    # ⚠️ ここはGlueジョブの設定に合わせて、削除したい一時ファイル（スクラッチ領域）のパスを設定してください
    correlation_id = decoded_payload.get('correlation_id')
    
    # 例: Glueスクラッチバケットが 'my-glue-scratch-bucket' で、
    # 実行ごとに 'sfn_executions/<correlation_id>/' 以下に一時ファイルを置く場合
    GLUE_SCRATCH_BUCKET = "youtube-glue-job-script-1016" # 以前の定義から仮にこのバケットを使用
    
    # SFNのInput Keysを削除対象として利用する場合 (Lambdaが置いた中間ファイルの削除)
    s3_input_channel_key = urlparse(decoded_payload.get('input_keys', [None, None, None])[0]).path.lstrip('/')
    s3_input_video_key = urlparse(decoded_payload.get('input_keys', [None, None, None])[1]).path.lstrip('/')
    s3_input_comment_key = urlparse(decoded_payload.get('input_keys', [None, None, None])[2]).path.lstrip('/')
    
    # 2. S3クリーンアップの実行
    if GLUE_SCRATCH_BUCKET and correlation_id:
        # **最も重要なクリーンアップ: Glueジョブの実行時一時ディレクトリ**
        glue_scratch_prefix = f"sfn_scratch/{correlation_id}/" # 実行IDベースのスクラッチパスを削除 (仮)
        # delete_s3_prefix(GLUE_SCRATCH_BUCKET, glue_scratch_prefix) 
        
        # **Lambdaが置いた生データの中間ファイルを削除**
        # ⚠️ SFNの設計次第で、この生データは保持するかもしれません
        # delete_s3_prefix(GLUE_SCRATCH_BUCKET, s3_input_channel_key)
        # delete_s3_prefix(GLUE_SCRATCH_BUCKET, s3_input_video_key)
        # delete_s3_prefix(GLUE_SCRATCH_BUCKET, s3_input_comment_key)


    # 3. Glueカタログのクリーンアップの実行 (必要な場合)
    # 例: Glueジョブが一時テーブル 'temp_video_data' を作成した場合
    # delete_glue_table(database_name="etl_database", table_name="temp_video_data")

    return {
        'statusCode': 200,
        'body': 'Cleanup attempt finished.'
    }