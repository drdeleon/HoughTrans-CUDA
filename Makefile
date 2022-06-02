all: pgm.o	houghBase houghTransPro

houghBase:	houghBase.cu pgm.o
	nvcc houghBase.cu pgm.o -o houghBase

houghTransPro:	houghTransPro.cu pgm.o
	nvcc houghTransPro.cu pgm.o -o houghTransPro

pgm.o:	pgm.cpp
	g++ -c pgm.cpp -o ./pgm.o

clean:
	rm houghBase pgm.o houghTransPro
