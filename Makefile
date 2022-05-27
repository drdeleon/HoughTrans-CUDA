all: pgm.o	houghBase

houghBase:	houghBase.cu pgm.o
	nvcc houghBase.cu pgm.o -o houghBase

pgm.o:	pgm.cpp
	g++ -c pgm.cpp -o ./pgm.o
