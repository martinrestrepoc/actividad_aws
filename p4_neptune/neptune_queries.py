import requests
import json
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NEPTUNE_URL = "https://localhost:8182/gremlin"

def execute_query(query, description=""):
    print(f"\n--- {description} ---")
    print(f"Consulta: {query}")
    
    payload = {
        "gremlin": query
    }
    
    try:
        response = requests.post(
            NEPTUNE_URL,
            json=payload,
            verify=False
        )
        
        if response.status_code == 200:
            result = response.json()
            data = result.get('result', {}).get('data', [])
            print(f"Resultado: {json.dumps(data, indent=2)}")
            return data
        else:
            print(f"Error del servidor ({response.status_code}): {response.text}")
    except Exception as e:
        print(f"Error ejecutando consulta: {e}")

def main():
    print("Iniciando consultas a Neptune via REST API...")

    execute_query("g.V().drop()", "Limpiar Grafo")

    insert_vertices_query = """
    g.addV('Person').property(id, 'p1').property('name', 'Alice')
     .addV('Person').property(id, 'p2').property('name', 'Bob')
     .addV('Person').property(id, 'p3').property('name', 'Charlie')
     .addV('Person').property(id, 'p4').property('name', 'David')
     .addV('Person').property(id, 'p5').property('name', 'Eve')
     .addV('Person').property(id, 'p6').property('name', 'Frank')
     .addV('Person').property(id, 'p7').property('name', 'Grace')
     .addV('City').property(id, 'c1').property('name', 'New York')
     .addV('City').property(id, 'c2').property('name', 'London')
     .addV('City').property(id, 'c3').property('name', 'Tokyo')
    """
    execute_query(insert_vertices_query, "Insertar Vértices")

    insert_edges_query = """
    g.V('p1').addE('KNOWS').to(V('p2'))
     .V('p1').addE('KNOWS').to(V('p3'))
     .V('p2').addE('KNOWS').to(V('p4'))
     .V('p3').addE('KNOWS').to(V('p5'))
     .V('p4').addE('KNOWS').to(V('p6'))
     .V('p5').addE('KNOWS').to(V('p7'))
     .V('p6').addE('KNOWS').to(V('p1'))
     .V('p7').addE('KNOWS').to(V('p2'))
     .V('p1').addE('LIVES_IN').to(V('c1'))
     .V('p2').addE('LIVES_IN').to(V('c2'))
     .V('p3').addE('LIVES_IN').to(V('c1'))
     .V('p4').addE('LIVES_IN').to(V('c3'))
     .V('p5').addE('LIVES_IN').to(V('c2'))
     .V('p6').addE('LIVES_IN').to(V('c3'))
     .V('p7').addE('LIVES_IN').to(V('c1')).iterate()
    """
    execute_query(insert_edges_query, "Insertar Relaciones")

    # 4. Tres Consultas que recorren relaciones

    # Consulta 1: ¿A quién conoce Alice?
    q1 = "g.V('p1').out('KNOWS').values('name')"
    execute_query(q1, "Consulta 1: Personas que Alice (p1) conoce directamente")

    # Consulta 2: Ciudades donde viven las personas que Bob conoce
    q2 = "g.V('p2').out('KNOWS').out('LIVES_IN').values('name')"
    execute_query(q2, "Consulta 2: Ciudades donde viven las personas que Bob (p2) conoce")

    # Consulta 3: Camino de conocidos entre Alice y Frank
    q3 = "g.V('p1').repeat(out('KNOWS')).until(hasId('p6')).path().by('name')"
    execute_query(q3, "Consulta 3: Camino de conocidos entre Alice y Frank")

if __name__ == "__main__":
    main()
