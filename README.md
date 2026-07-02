# Controle Digital de Velocidade de um Motor Universal

Este repositório contém os arquivos desenvolvidos para o projeto de controle digital de velocidade de um motor universal, utilizando identificação experimental da planta, projeto de controladores PI, discretização e implementação em microcontrolador.

O objetivo do trabalho foi modelar a bancada experimental, projetar diferentes métodos de sintonia de controladores e comparar o comportamento do sistema em simulação e na prática, considerando ensaios com e sem carga mecânica.

## Descrição do Projeto

O sistema estudado é composto por um motor universal, circuito de acionamento, sensor de velocidade e microcontrolador responsável pela execução do algoritmo de controle. A identificação da planta foi realizada a partir da resposta ao degrau experimental, obtendo-se um modelo aproximado de primeira ordem.

A partir desse modelo, foram projetados e analisados diferentes controladores, com foco na comparação entre desempenho, estabilidade, sobressinal, tempo de acomodação e comportamento experimental da bancada.

## Métodos Utilizados

Foram analisados os seguintes métodos de sintonia:

- Root Locus por cancelamento polo-zero;
- Ziegler-Nichols em malha aberta;
- CHR;
- IMC;
- Root Locus Clássico;
- Deadbeat, mantido como método digital direto.

Os controladores PI foram discretizados utilizando três técnicas:

- Tustin;
- Euler Progressivo;
- Euler Regressivo.

A discretização foi necessária para permitir a implementação dos controladores no microcontrolador. O período de amostragem adotado foi de 100 ms, buscando um compromisso adequado entre precisão da resposta dinâmica, estabilidade da leitura e esforço computacional.

## Implementação

O controle foi implementado em microcontrolador utilizando a forma incremental do controlador PI:

```math
u(k) = u(k-1) + q_0e(k) + q_1e(k-1)
<img width="1875" height="502" alt="image" src="https://github.com/user-attachments/assets/af76e193-d5cc-47d3-be24-a2adf3572325" />
