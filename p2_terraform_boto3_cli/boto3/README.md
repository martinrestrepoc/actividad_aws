# boto3

Desde la carpeta `actividad_aws`, con el perfil AWS `default` configurado como `user_cli`:

```bash
uv run p2_terraform_boto3_cli/boto3/infraestructura.py verificar
uv run p2_terraform_boto3_cli/boto3/infraestructura.py crear
uv run p2_terraform_boto3_cli/boto3/infraestructura.py estado
uv run p2_terraform_boto3_cli/boto3/infraestructura.py eliminar
```

Ejecutar uno a la vez. `crear` y `eliminar` piden confirmar con `si`. La región es `us-east-1`.

No borrar `.runtime/recursos.json` mientras existan recursos. La eliminación de RDS no conserva un snapshot final.
