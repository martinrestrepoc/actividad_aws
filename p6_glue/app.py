import json
import boto3
import time
import sys

# ================= CONFIGURACIÓN =================
try:
    with open('config.json', 'r') as f:
        config = json.load(f)
except FileNotFoundError:
    print("Error: Ejecuta 'terraform apply' primero en la carpeta p6_glue.")
    sys.exit(1)

S3_DATA_BUCKET = config['S3_DATA_BUCKET']
S3_ATHENA_BUCKET = config['S3_ATHENA_BUCKET']
GLUE_DB = config['GLUE_DB']
CRAWLER_NAME = config['CRAWLER_NAME']
REGION = config['REGION']
# =================================================

s3_client = boto3.client('s3', region_name=REGION)
glue_client = boto3.client('glue', region_name=REGION)
athena_client = boto3.client('athena', region_name=REGION)

def upload_to_s3(filename, target_path):
    print(f"-> Subiendo {filename} a s3://{S3_DATA_BUCKET}/{target_path}...")
    s3_client.upload_file(filename, S3_DATA_BUCKET, target_path)

def run_crawler():
    print(f"-> Iniciando Crawler '{CRAWLER_NAME}'...")
    glue_client.start_crawler(Name=CRAWLER_NAME)
    
    while True:
        response = glue_client.get_crawler(Name=CRAWLER_NAME)
        state = response['Crawler']['State']
        if state == 'READY':
            print("   Crawler finalizó y actualizó el catálogo de datos.")
            break
        print(f"   Crawler en estado: {state}... esperando 10s")
        time.sleep(10)

def execute_athena_query(query):
    print(f"\n-> Ejecutando consulta en Athena:\n{query}")
    response = athena_client.start_query_execution(
        QueryString=query,
        QueryExecutionContext={'Database': GLUE_DB},
        ResultConfiguration={'OutputLocation': f"s3://{S3_ATHENA_BUCKET}/resultados/"}
    )
    
    execution_id = response['QueryExecutionId']
    
    while True:
        status_response = athena_client.get_query_execution(QueryExecutionId=execution_id)
        state = status_response['QueryExecution']['Status']['State']
        if state in ['SUCCEEDED', 'FAILED', 'CANCELLED']:
            break
        print("   Esperando resultados de Athena...")
        time.sleep(3)
        
    if state == 'SUCCEEDED':
        results = athena_client.get_query_results(QueryExecutionId=execution_id)
        rows = results['ResultSet']['Rows']
        print("\n--- RESULTADOS ---")
        for row in rows:
            data = [col.get('VarCharValue', '') for col in row['Data']]
            print(" | ".join(f"{val:<15}" for val in data))
        print("------------------")
    else:
        print(f"   Error en Athena: {status_response['QueryExecution']['Status']['StateChangeReason']}")

def main():
    # 1. Subir primeros 25 registros
    upload_to_s3('ventas_iniciales.csv', 'datos_ventas/ventas_iniciales.csv')
    
    # 2. Correr crawler por primera vez
    run_crawler()
    
    # El crawler crea una tabla automáticamente con el nombre de la carpeta
    table_name = "datos_ventas"
    
    # 3. Consulta en Athena (Filtro y Agrupación como pide el PDF)
    # Queremos saber el total recaudado por categoría de productos electrónicos o muebles
    query_1 = f"""
    SELECT categoria, COUNT(*) as cantidad_ventas, SUM(precio * unidades) as total_recaudado
    FROM {table_name}
    WHERE categoria IN ('Electronica', 'Muebles')
    GROUP BY categoria;
    """
    execute_athena_query(query_1)
    
    # 4. Pausa para instrucción
    input("\nPresiona ENTER para subir los nuevos registros (actualizar catálogo)...")
    
    # 5. Agregar nuevos registros a S3 (simulando que llegaron más datos)
    upload_to_s3('ventas_nuevas.csv', 'datos_ventas/ventas_nuevas.csv')
    
    # 6. Volver a correr el crawler (Actualiza el catálogo)
    run_crawler()
    
    # 7. Volver a consultar Athena para ver que los datos aumentaron
    print("\nConsultando de nuevo tras actualizar el catálogo...")
    execute_athena_query(query_1)

if __name__ == '__main__':
    main()
