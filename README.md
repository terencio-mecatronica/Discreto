# Página do projeto

Este pacote contém uma página estática simples para o projeto de controle digital de velocidade do motor.

## Estrutura sugerida no repositório

```text
seu-repositorio/
├── docs/
│   ├── index.html
│   └── style.css
├── codigo/
│   ├── classico_corrigido_gptatualizado_sem_tracejado.m
│   └── controlador_motor.ino
├── dados/
│   ├── sem carga (1).zip
│   ├── com carga.zip
│   ├── zieglernichols_sem_carga.txt
│   └── zieglernichols_com_carga.txt
└── relatorio/
    └── relatorio.pdf
```

## Como publicar no GitHub Pages

1. Envie a pasta `docs` para o repositório.
2. No GitHub, abra o repositório.
3. Vá em `Settings` > `Pages`.
4. Em `Build and deployment`, selecione `Deploy from a branch`.
5. Escolha a branch `main` e a pasta `/docs`.
6. Salve e aguarde a publicação.

Depois disso, o GitHub irá gerar um link público para a página do projeto.
