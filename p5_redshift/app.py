import json
import boto3
import time
import sys

# ================= CONFIGURACIÓN =================
try:
    with open('config.json', 'r') as f:
        config = json.load(f)
except FileNotFoundError:
    print("Error: No se encontró 'config.json'. Ejecuta 'terraform apply' primero.")
    sys.exit(1)

S3_BUCKET = config['S3_BUCKET']
WORKGROUP = config['WORKGROUP']
DATABASE = config['DATABASE']
SECRET_ARN = config['SECRET_ARN']
IAM_ROLE_ARN = config['IAM_ROLE_ARN']
REGION = config['REGION']
# =================================================

s3_client = boto3.client('s3', region_name=REGION)
redshift_data = boto3.client('redshift-data', region_name=REGION)

def upload_to_s3():
    print("1. Subiendo archivos CSV a S3...")
    s3_client.upload_file('departments.csv', S3_BUCKET, 'departments.csv')
    s3_client.upload_file('employees.csv', S3_BUCKET, 'employees.csv')
    print("   Archivos subidos exitosamente.")

def execute_sql(sql_query, description):
    print(f"\n-> Ejecutando: {description}")
    
    try:
        response = redshift_data.execute_statement(
            WorkgroupName=WORKGROUP,
            Database=DATABASE,
            SecretArn=SECRET_ARN,
            Sql=sql_query
        )
    except Exception as e:
        print(f"   Error lanzando la consulta: {e}")
        return None

    query_id = response['Id']
    
    while True:
        status_response = redshift_data.describe_statement(Id=query_id)
        status = status_response['Status']
        if status in ['FINISHED', 'FAILED', 'ABORTED']:
            break
        print("   Esperando a que termine la consulta...")
        time.sleep(2)
        
    if status == 'FINISHED':
        print("   Consulta finalizada con éxito.")
        if status_response.get('HasResultSet'):
            results = redshift_data.get_statement_result(Id=query_id)
            return results['Records']
    else:
        print(f"   Error en la consulta: {status_response.get('Error')}")
    return None

def get_val(col):
    """Extrae el valor del diccionario de respuesta de Redshift"""
    if 'stringValue' in col: return col['stringValue']
    if 'longValue' in col: return str(col['longValue'])
    return ""

def main():
    upload_to_s3()

    sql_create = """
    CREATE TABLE IF NOT EXISTS departments (
        dept_id INT PRIMARY KEY,
        dept_name VARCHAR(50)
    );
    CREATE TABLE IF NOT EXISTS employees (
        emp_id INT PRIMARY KEY,
        emp_name VARCHAR(50),
        dept_id INT,
        salary DECIMAL(10,2)
    );
    """
    execute_sql(sql_create, "Creación de tablas")

    execute_sql(f"COPY departments FROM 's3://{S3_BUCKET}/departments.csv' IAM_ROLE '{IAM_ROLE_ARN}' CSV;", "Carga a departments")
    execute_sql(f"COPY employees FROM 's3://{S3_BUCKET}/employees.csv' IAM_ROLE '{IAM_ROLE_ARN}' CSV;", "Carga a employees")

    print("\n" + "="*50)
    
    # 1. Consulta Filtro
    sql_filtro = "SELECT emp_name, salary FROM employees WHERE salary >= 3000;"
    rec_filtro = execute_sql(sql_filtro, "Consulta 1: FILTRO (WHERE salary >= 3000)")
    print("--- RESULTADO CONSULTA 1 ---")
    if rec_filtro:
        for row in rec_filtro:
            print(f"Empleado: {get_val(row[0]):<15} | Salario: {get_val(row[1])}")

    # 2. Consulta Unión
    sql_union = "SELECT e.emp_name, d.dept_name FROM employees e JOIN departments d ON e.dept_id = d.dept_id;"
    rec_union = execute_sql(sql_union, "Consulta 2: UNIÓN (JOIN departments)")
    print("--- RESULTADO CONSULTA 2 ---")
    if rec_union:
        for row in rec_union:
            print(f"Empleado: {get_val(row[0]):<15} | Departamento: {get_val(row[1])}")

    # 3. Consulta Agregación
    sql_agreg = "SELECT dept_id, COUNT(emp_id) as total_emp FROM employees GROUP BY dept_id;"
    rec_agreg = execute_sql(sql_agreg, "Consulta 3: AGREGACIÓN (GROUP BY dept_id)")
    print("--- RESULTADO CONSULTA 3 ---")
    if rec_agreg:
        for row in rec_agreg:
            print(f"ID Depto: {get_val(row[0]):<15} | Total Empleados: {get_val(row[1])}")
            
    print("="*50 + "\n")

if __name__ == '__main__':
    main()
