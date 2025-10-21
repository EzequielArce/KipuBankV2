# KipuBankV2
*Mejoras Realizadas*
Se implemento un control de acceso donde se creo el rol de administrador, el cual permite añadir feeds y tokens, esto permite un soporte multi-token controlado, esto se realizo medianto los contratos de OpenZeppelin que estan propiamente auditados y son de confianza.
Se implemneto un soorte multi-token para los tokens habilitados por los administradores.
Dentro del contrato toda la contabilidad interna se mantiene mediante en USD
Se añadieron más eventos y errores correspondientes a las funciones agregadas
Para permitir multi-tokens y poder pasar todas las tokens a USD, se utilizadors Data Feeds de ChainLink, de esta manera se puede llevar de una manera controlada la contabilidad interna del contrato en USD

*Instrucciones de despliegue*
constructor(_banckCap,_witchdrawalThreshold)
_bankCap: Capacidad máxima total del banco en USD
_withdrawalThreshold: Límite máximo de retiro por transacción en USD
La direccion que despliega el contrato, es asignado automaticamente como administrador
Ambos valores deben ser mayores que 0

*Como interactuar con el contrato*
Funciones Externas
1. Depositar ETH o Tokens
function deposit(address token, uint256 amount) external payable
Parámetros:
token: Dirección del token ERC20. Usar address(0) para ETH.
amount: Cantidad a depositar (ETH en wei o tokens).

2. Retirar ETH o Tokens
function withdraw(address token, uint256 amount) external
Parámetros:
token: Dirección del token ERC20. Usar address(0) para ETH.
amount: Cantidad a retirar.
Notas:
No se puede retirar más que el balance del usuario ni superar el límite por transacción.


3. Agregar un Oráculo de Chainlink
function addFeed(address token, address feed) external onlyRole(ADMIN_ROLE)
Parámetros:
token: Dirección del token (o address(0) para ETH).
feed: Dirección del contrato de Chainlink para obtener el precio en USD.

4. Actualizar Capacidad del Banco
function setBankCapacity(uint256 newCapacity) external onlyRole(ADMIN_ROLE)
Cambia la capacidad total del banco en USD-equivalente.
No se puede establecer un valor menor que el total depositado.

5. Actualizar Límite de Retiro
function setWithdrawalThreshold(uint256 newThreshold) external onlyRole(ADMIN_ROLE)
Define el máximo que un usuario puede retirar por transacción en USD-equivalente.

6. Gestión de Roles de Administrador
Otorgar ADMIN:
function grantAdminRole(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE)
Revocar ADMIN:
function revokeAdminRole(address removeThisAdmin) external onlyRole(DEFAULT_ADMIN_ROLE)

7. Funciones de Consulta (View)

viewBalanceSpecificToken(token): Retorna el saldo USD-equivalente del usuario para un token.

viewDepositCount(): Retorna el total de depósitos.

viewWithdrawCount(): Retorna el total de retiros.

viewWithdrawalThreshold(): Retorna el límite de retiro por transacción.

viewBankCapacity(): Retorna la capacidad total del banco.

*Notas importantes y trade-off:*
Dépositos de ETH usan address(0) como token.
Para poder llevar toda la contabilidad interna del contrato en USD y de esta manera poder comparar si la capacidad habia sido sobrepasada, se debio pasar todos los tokens ingresados a USD y almacenarlos de esta manera, esto conlleva un problema en el momento en que un usuario intente realizar un retiro porque el precio del token pudo haber variado, por lo tanto, en el momento de retiro se realiza una consulta para saber cuanto vale en ese momento el token que desea retirar y si la cantidad de dolares de ese token que el usuario tiene permitiria esa operación.
Cada usuario tiene varios tokens asociados a él, el valor de los tokens no se suman, son todos considerados diferentes.
