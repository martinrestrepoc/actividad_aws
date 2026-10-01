# aws cli

Desde `actividad_aws`, con AWS CLI y jq instalados:

```bash
bash p2_terraform_boto3_cli/cli/crear.sh
bash p2_terraform_boto3_cli/cli/estado.sh
bash p2_terraform_boto3_cli/cli/eliminar.sh
```

Ejecutar uno a la vez. Se usa el perfil `default` como `user_cli` en `us-east-1`.
Crear y eliminar piden confirmar con `si`. RDS se elimina sin snapshot final.

Los ids y evidencias quedan en `.runtime/`. No borres el inventario si quedan recursos.
Si falla una creación, consulta el estado y limpia con `eliminar.sh`; no repitas la creación.
Si se pierde la respuesta de una solicitud, revisa también la etiqueta `RunId` en AWS.
Los waiters pueden agotar su tiempo aunque AWS siga trabajando; consulta el estado antes de continuar.
